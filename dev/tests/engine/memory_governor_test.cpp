#include "TestChecks.hpp"
#include "TestMetalMemory.hpp"
#include "TestModel.hpp"
#include "engine/MemoryGovernor.hpp"
#include "engine/Engine.hpp"
#include "engine/MemoryPlan.hpp"
#include "engine/ResourceDomainLease.hpp"

#include <mach/mach.h>

#include <cstdlib>
#include <functional>
#include <future>
#include <iostream>
#include <limits>
#include <optional>
#include <span>
#include <stdexcept>
#include <string>
#include <thread>

using namespace splash;
using namespace splash::engine;

namespace {

using splash::test::rejects;
using splash::test::require;

// Admits bytes through the governor's one admission path for a claim of
// `cls`, open while it runs (a start's Floor claim unless the test names
// another), running allocate while they are reserved.
metal::AllocationResult admit(MemoryGovernor &governor, uint64_t bytes,
                              const std::function<void()> &allocate = [] {},
                              ClaimClass cls = ClaimClass::Floor) {
  const ClaimId claim = governor.ledger().open({.cls = cls});
  metal::AllocationResult result;
  {
    const MemoryGovernor::Scope scope(governor, claim);
    result = governor.allocationAdmission()(bytes, allocate);
  }
  governor.ledger().close(claim);
  governor.publishSnapshot();
  return result;
}

// A host whose spare memory is all its available memory: no anonymous
// pages to compress.
std::optional<HostMemory> hostMemory(std::optional<uint64_t> bytes) {
  if (!bytes)
    return std::nullopt;
  return HostMemory{*bytes, *bytes};
}

// Charges bytes to the backend, as an allocation does.
void allocate(uint64_t bytes) {
  test::metalStatistics().allocatedBytes += bytes;
  test::metalStatistics().deviceCurrentAllocatedBytes += bytes;
}

// Available host memory is what macOS can hand out without swapping: free, pageable file-backed and purgeable
// pages, plus what compression frees.
void testHostAvailabilityCountsReclaimablePages() {
  constexpr uint64_t pageSize = 16384;
  auto availablePages = [](const HostMemoryPages &pages) {
    return estimateHostMemory(pages, pageSize, false).available / pageSize;
  };
  // free_count includes the speculative pages; they are file-backed too.
  HostMemoryPages pages{
      .free = 15, .speculative = 5, .fileBacked = 35, .purgeable = 5};
  require(availablePages(pages) == 50,
          "host availability does not match macOS reclaimable accounting");
  pages.free += 5;
  pages.speculative += 5;
  require(availablePages(pages) == 50,
          "speculative file pages were counted twice");
  pages.free -= 10;
  require(availablePages(pages) == 40,
          "anonymous or compressed pages did not consume capacity");
  pages.purgeable = 0;
  require(availablePages(pages) == 35,
          "non-purgeable backing received reclaimable credit");
  // Wired file pages leave external_page_count: pinned pages must reduce
  // available memory rather than count as reclaimable.
  pages.fileBacked -= 10;
  require(availablePages(pages) == 25,
          "wired file pages remained available for new allocations");

  // Clean file cache is reclaimable: reading a file takes no capacity from
  // a later allocation.
  require(availablePages({.free = 75}) == 75 &&
              availablePages({.free = 35, .fileBacked = 40}) == 75,
          "clean file cache reduced allocation capacity");
  const uint64_t maximum = std::numeric_limits<uint64_t>::max();
  const auto none = [](const HostMemory &host) { return !host.available && !host.spare; };
  require(none(estimateHostMemory({.free = maximum, .fileBacked = 1}, 1, false)) &&
              none(estimateHostMemory({.fileBacked = maximum, .purgeable = 1}, 1, false)) &&
              none(estimateHostMemory({.free = maximum}, pageSize, false)) &&
              none(estimateHostMemory({.free = 1, .speculative = 2}, 1, false)) &&
              estimateHostMemory({.free = maximum}, 1, false).available == maximum &&
              none(estimateHostMemory(pages, 0, false)),
          "invalid host counters or arithmetic overflow did not fail closed");
  // With compression (below critical system pressure), compressing the
  // anonymous pages frees what the compressor would not keep: at its
  // present ratio, at most 2:1, and 2:1 while it holds nothing. The spare
  // memory counts half of that credit.
  const auto compressedPages = [](uint64_t compressor, uint64_t compressed) {
    return estimateHostMemory({.free = 10, .fileBacked = 20, .anonymous = 40,
                               .compressor = compressor, .compressed = compressed},
                              1, true);
  };
  const auto both = [](const HostMemory &host, uint64_t available, uint64_t spare) {
    return host.available == available && host.spare == spare;
  };
  require(both(estimateHostMemory({.free = 10, .fileBacked = 20, .anonymous = 40}, 1, false), 30, 30) &&
              both(compressedPages(0, 0), 50, 40) && both(compressedPages(10, 15), 44, 37) &&
              both(compressedPages(10, 40), 50, 40) && both(compressedPages(10, 10), 30, 30) &&
              both(compressedPages(10, 5), 30, 30),
          "compression credit is not the anonymous pages' savings at the compressor's ratio, at most 2:1, "
          "and half of it in the spare memory");
  require(none(estimateHostMemory({.free = maximum, .anonymous = 2}, 1, true)),
          "compression credit overflowed");
  require(EngineMemoryPolicy::hostAvailableReserveBytes(16 * kGiB) ==
                  16 * kGiB / 10 &&
              EngineMemoryPolicy::hostAvailableReserveBytes(48 * kGiB) ==
                  2 * kGiB &&
              EngineMemoryPolicy::hostAvailableReserveBytes(128 * kGiB) ==
                  2 * kGiB,
          "the macOS reserve is a tenth of a small machine, 2 GiB above 20 GiB");
  require(EngineMemoryPolicy::hostSpareReserveBytes(16 * kGiB) == 2 * kGiB &&
              EngineMemoryPolicy::hostSpareReserveBytes(24 * kGiB) == 2 * kGiB &&
              EngineMemoryPolicy::hostSpareReserveBytes(64 * kGiB) == 64 * kGiB / 100 * 7 &&
              EngineMemoryPolicy::hostSpareReserveBytes(128 * kGiB) == 7 * kGiB,
          "the spare reserve is 7% of the Mac's memory, from 2 to 7 GiB");
}

// A Mac whose recommended working set is numerator/denominator of its memory,
// as Metal reports it (2/3 at 32 GB, 3/4 at 36 GB).
DeviceCapabilities mac(uint64_t physicalGiB, uint64_t numerator,
                       uint64_t denominator) {
  DeviceCapabilities device;
  device.deviceName = "governor-test";
  device.appleGpuFamily = 9;
  device.macosMajor = 26;
  device.macosMinor = 4;
  device.physicalMemoryBytes = physicalGiB * kGiB;
  device.recommendedMaxWorkingSetBytes =
      device.physicalMemoryBytes / denominator * numerator;
  device.maxBufferLengthBytes = device.recommendedMaxWorkingSetBytes;
  device.maxThreadgroupMemoryBytes = 32 * 1024;
  device.maxThreadgroupWidth = 1024;
  device.hasUnifiedMemory = true;
  return device;
}

// Grows one request's KV extent by extent, as PageStorage allocates it, and
// returns the pages the governor granted.
uint32_t grantKvPages(MemoryGovernor &governor,
                      const EngineMemoryBreakdown &budget) {
  uint32_t granted = 0;
  while (granted < budget.kvCapacityPages) {
    const uint32_t pages = budget.kvExtentPages;
    const uint64_t bytes = uint64_t{pages} * budget.kvPageBytes;
    if (!admit(governor, bytes, [bytes] { allocate(bytes); }))
      break;
    granted += pages;
  }
  return granted;
}

// One request reaches the advertised context through the plan's governor whatever part of the reserves Metal's
// untracked memory takes; memory beyond the reserves is charged, and the device never passes the hard budget.
void testAdvertisedContextIsGrantable() {
  struct Machine {
    const char *name;
    uint64_t physicalGiB, numerator, denominator;
    kv::Format format;
  };
  for (const Machine &machine :
       {Machine{"32 GB INT8", 32, 2, 3, kv::Format::Int8},
        Machine{"36 GB INT8", 36, 3, 4, kv::Format::Int8},
        Machine{"36 GB BF16", 36, 3, 4, kv::Format::BFloat16}}) {
    // The 27B with its draft and vision tower: 16.2 GiB of weights.
    ModelMemoryProfile model =
        test::modelMemoryProfile(15 * kGiB, kGiB / 2, 7 * kGiB / 10);
    model.targetKvLayout.format = machine.format;
    const EngineMemoryPlan plan = test::requireMemoryPlan(
        mac(machine.physicalGiB, machine.numerator, machine.denominator),
        model);
    const EngineMemoryBreakdown &budget = plan.breakdown();
    const uint64_t reserves =
        budget.pipelineReserveBytes + budget.runtimeOverheadReserveBytes;
    for (const uint64_t untracked :
         {uint64_t{0}, 64 * kMiB, 150 * kMiB, 300 * kMiB, reserves,
          reserves + 256 * kMiB}) {
      // After warmup the weights, the arenas and the request's lane state
      // are the backend's buffers; Metal holds the untracked bytes besides.
      test::metalStatistics() = {};
      test::metalStatistics().allocatedBytes =
          budget.targetWeightsBytes + budget.draftWeightsBytes +
          budget.visionWeightsBytes + budget.sharedPrefillBytes +
          budget.sharedDecodeBytes + budget.laneStateBytes;
      test::metalStatistics().deviceCurrentAllocatedBytes =
          test::metalStatistics().allocatedBytes + untracked;
      metal::MetalBackend backend("unused");
      // The plan's governor, as a start and the runtime oracle build it.
      MemoryGovernor governor(backend, budget, [] { return hostMemory(200 * kGiB); });
      const uint32_t granted = grantKvPages(governor, budget);
      const std::string context = std::string(machine.name) + ", " +
                                  std::to_string(untracked / kMiB) +
                                  " MiB untracked: granted " +
                                  std::to_string(granted) + " of " +
                                  std::to_string(budget.kvCapacityPages) +
                                  " KV pages";
      require(test::metalStatistics().deviceCurrentAllocatedBytes <=
                  budget.hardBudgetBytes,
              context + ", beyond the hard budget");
      if (untracked <= reserves)
        require(granted == budget.kvCapacityPages,
                context + ", short of the advertised context");
      else
        require(granted < budget.kvCapacityPages,
                context + ", memory beyond the reserves was not charged");
    }
  }
}

// A reservation holds exactly its bytes while its allocation runs; a driver denial or a backend defect releases it.
void testReservationsAndAdmissionClasses() {
  test::metalStatistics() = {};
  metal::MetalBackend backend("unused");
  const uint64_t hostReserve = 64 * 1024;
  const uint64_t limit = 64 * 1024;
  MemoryGovernor governor(backend, limit, hostReserve, hostReserve,
                          [] { return hostMemory(hostReserve + 3 * kGiB); }, 0);
  const metal::AllocationResult held = admit(governor, limit - 1, [&] {
    require(static_cast<bool>(admit(governor, 1)),
            "memory governor held more than the reserved bytes");
    const metal::AllocationResult over = admit(governor, 2);
    require(!over && over.failure == metal::AllocationFailure::EngineBudget &&
                governor.snapshot().deniedReservations == 1,
            "memory governor oversold its limit");
  });
  require(static_cast<bool>(held), "memory governor refused bytes under its limit");
  const metal::AllocationResult driverDenied = admit(governor, 1024, [] {
    throw metal::MetalAllocationError("injected driver allocation denial");
  });
  require(!driverDenied &&
              driverDenied.failure == metal::AllocationFailure::DriverRejected &&
              admit(governor, limit),
          "driver allocation denial did not release its reservation");
  rejects(
      [&] {
        static_cast<void>(admit(governor, 1024, [] {
          throw metal::MetalBackendError("injected backend defect");
        }));
      },
      "injected backend defect", "admission swallowed a backend defect");
  require(static_cast<bool>(admit(governor, limit)),
          "a backend defect leaked its reservation");
}

// Host memory the engine holds outside Metal (a streamed table's row cache) is charged beside the backend's
// buffers.
void testHostHeldBytesAreCharged() {
  test::metalStatistics() = {};
  metal::MetalBackend backend("unused");
  const uint64_t hostReserve = 64 * 1024;
  const uint64_t limit = 64 * 1024, held = 16 * 1024;
  MemoryGovernor governor(backend, limit, hostReserve, hostReserve, [] {
    return hostMemory(hostReserve + 3 * kGiB);
  }, 0, held);
  require(static_cast<bool>(admit(governor, limit - held)) && !admit(governor, limit - held + 1),
          "memory governor did not charge the host memory the engine holds");
  require(governor.snapshot().chargedBytes == held, "the host memory the engine holds is not in its charge");
}

// A refusal the host and the engine's limit share is the host's; an exempted in-service claim meets only the limit,
// except under critical pressure.
void testHostRefusalComesBeforeTheEngineLimit() {
  test::metalStatistics() = {};
  test::metalStatistics().allocatedBytes = 14 * kGiB;
  test::metalStatistics().deviceCurrentAllocatedBytes = 14 * kGiB;
  metal::MetalBackend backend("unused");
  const uint64_t hostReserve = 2 * kGiB;
  std::optional<uint64_t> available = hostReserve + kGiB / 2;
  MemoryGovernor governor(backend, 15 * kGiB, hostReserve, hostReserve, [&available] { return hostMemory(available); }, 0);
  const metal::AllocationResult shared = admit(governor, 2 * kGiB, [] {}, ClaimClass::Start);
  require(!shared && shared.failure == metal::AllocationFailure::HostPressure,
          "a refusal the host shares was reported as the engine's");
  const ClaimId inService = governor.ledger().open({.cls = ClaimClass::InService});
  const auto attempt = [&] {
    const MemoryGovernor::Scope scope(governor, inService);
    return governor.allocationAdmission()(2 * kGiB, [] {});
  };
  require(attempt().failure == metal::AllocationFailure::HostPressure &&
              governor.free(inService, governor.need(inService)).outcome == FreeOutcome::Met,
          "the host's margin did not refuse an in-service claim before free() exempted it");
  const metal::AllocationResult exempt = attempt();
  require(!exempt && exempt.failure == metal::AllocationFailure::EngineBudget,
          "the host's margin refused an in-service claim it exempted");
  governor.setPressure(MemoryPressure::Critical);
  static_cast<void>(governor.evaluate());
  const metal::AllocationResult critical = attempt();
  require(!critical && critical.failure == metal::AllocationFailure::HostPressure,
          "critical pressure was reported as the engine's limit");
  governor.ledger().close(inService);
}

// An allocation outside any claim's scope is a defect the governor refuses loudly.
void testAnAllocationOutsideAClaimThrows() {
  test::metalStatistics() = {};
  metal::MetalBackend backend("unused");
  MemoryGovernor governor(backend, 4 * kGiB, kGiB, kGiB, [] { return hostMemory(8 * kGiB); }, 0);
  bool allocated = false;
  rejects([&] { static_cast<void>(governor.allocationAdmission()(4096, [&] { allocated = true; })); },
          "outside a claim's scope", "an allocation outside a claim was admitted");
  require(!allocated && governor.snapshot().deniedReservations == 0 && admit(governor, 4096),
          "an allocation outside a claim ran, or one inside a claim was refused");
}

// What a scope's work released (fund) pays for that scope's allocations past the host's rule, under critical
// pressure too, as far as its bytes left go; a nested or later scope, of the same claim too, starts with none, and a
// release outside any scope is a defect.
void testReleasedBytesPayOnlyForTheirScope() {
  test::metalStatistics() = {};
  metal::MetalBackend backend("unused");
  MemoryGovernor governor(backend, 4 * kGiB, kGiB, kGiB, [] { return hostMemory(8 * kGiB); }, 0);
  governor.setPressure(MemoryPressure::Critical);
  static_cast<void>(governor.evaluate());
  rejects([&] { governor.fund(4096); }, "outside a claim's scope", "memory released outside a claim was credited");
  const metal::AllocationAdmission admission = governor.allocationAdmission();
  const auto admits = [&](uint64_t bytes) { return static_cast<bool>(admission(bytes, [] {})); };
  const auto hostRefuses = [&](uint64_t bytes) {
    const metal::AllocationResult result = admission(bytes, [] {});
    return !result && result.failure == metal::AllocationFailure::HostPressure;
  };
  const ClaimId claim = governor.ledger().open({.cls = ClaimClass::InService});
  {
    const MemoryGovernor::Scope scope(governor, claim);
    governor.fund(3 * 4096);
    require(admits(4096), "critical pressure refused an allocation its scope's releases paid for");
    {
      const MemoryGovernor::Scope nested(governor, claim);
      require(hostRefuses(4096), "a nested scope allocated on its outer scope's releases");
    }
    require(hostRefuses(3 * 4096) && admits(4096),
            "an allocation passed past what its scope's releases had left, or that refusal or a nested scope took "
            "them");
  }
  {
    const MemoryGovernor::Scope later(governor, claim);
    require(hostRefuses(4096), "a later scope of the claim allocated on an earlier scope's releases");
  }
  governor.ledger().close(claim);
}

// A Floor claim replaces the old essential-serving mark. Its nested scope
// grants only its own work and restores the prior claim even on unwind.
void testEssentialClaimScopeRestoresAdmissionPolicy() {
  test::metalStatistics() = {};
  metal::MetalBackend backend("unused");
  MemoryGovernor governor(backend, kGiB, 2 * kGiB, 2 * kGiB,
                          [] { return std::optional<HostMemory>(HostMemory{8 * kGiB, 0}); }, 0);
  const ClaimId optional = governor.ledger().open({.cls = ClaimClass::Optional});
  const ClaimId floor = governor.ledger().open({.cls = ClaimClass::Floor});
  const auto admission = governor.allocationAdmission();
  const auto admits = [&](uint64_t bytes) { return static_cast<bool>(admission(bytes, [] {})); };
  {
    const MemoryGovernor::Scope outer(governor, optional);
    require(!admits(1), "optional work crossed the host reserve");
    try {
      const MemoryGovernor::Scope essential(governor, floor);
      require(admits(1) && !admits(kGiB + 1), "Floor did not honor its essential and budget rights");
      governor.setPressure(MemoryPressure::Critical);
      require(!admits(1), "Floor bypassed critical pressure");
      governor.setPressure(MemoryPressure::Normal);
      throw std::runtime_error("unwind");
    } catch (const std::runtime_error &error) {
      require(std::string_view(error.what()) == "unwind", "essential claim failed before unwind");
    }
    require(!admits(1), "unwinding the Floor scope left essential rights in effect");
  }
  {
    const MemoryGovernor::Scope outer(governor, floor);
    { const MemoryGovernor::Scope nested(governor, optional); require(!admits(1), "nested optional work crossed the reserve"); }
    require(admits(1), "nested scope did not restore the prior Floor claim");
  }
  governor.ledger().close(floor);
  governor.ledger().close(optional);
}

// What a scope's work released pays for its allocations of no more than that past the engine's limit and the room a
// claim ranked above it holds, as past the host's rule: the scope's net change never raises the charge. Only memory
// allocated takes it back; a driver's denial leaves it.
void testReleasedBytesPayPastTheLimitAndTheHeldRoom() {
  test::metalStatistics() = {};
  metal::MetalBackend backend("unused");
  constexpr uint64_t limit = 4 * kGiB, room = 64 * kMiB;
  MemoryGovernor governor(backend, limit, kGiB, kGiB, [] { return hostMemory(8 * kGiB); }, 0);
  MemoryLedger &ledger = governor.ledger();
  const metal::AllocationAdmission admission = governor.allocationAdmission();
  const auto refusal = [&](uint64_t bytes) { return admission(bytes, [&] { allocate(bytes); }).failure; };
  const ClaimId claim = ledger.open({.cls = ClaimClass::InService});
  // Metal memory outside the backend's buffers holds the charge over the
  // limit, by more than the scope's work releases.
  allocate(limit - room);
  test::metalStatistics().deviceCurrentAllocatedBytes += 2 * room;
  {
    const MemoryGovernor::Scope scope(governor, claim);
    require(refusal(kMiB) == metal::AllocationFailure::EngineBudget, "an allocation past the engine's limit passed");
    test::metalStatistics().allocatedBytes -= 2 * kMiB;
    test::metalStatistics().deviceCurrentAllocatedBytes -= 2 * kMiB;
    governor.fund(2 * kMiB);
    const metal::AllocationResult denied =
        admission(2 * kMiB, [] { throw metal::MetalAllocationError("injected driver allocation denial"); });
    require(denied.failure == metal::AllocationFailure::DriverRejected &&
                refusal(2 * kMiB) == metal::AllocationFailure::None,
            "the engine's limit refused an allocation its scope's releases paid for, or a driver's denial took them");
    require(refusal(kMiB) == metal::AllocationFailure::EngineBudget,
            "an allocation passed the engine's limit on releases another allocation took back");
  }
  // A Foreground start ranked above the claim waits for its copies, holding
  // twice the room the limit leaves.
  test::metalStatistics().deviceCurrentAllocatedBytes = test::metalStatistics().allocatedBytes;
  const ClaimId start = ledger.open({.cls = ClaimClass::Start, .requestId = 1, .rank = {.priority = 2}});
  ledger.setReturning([] { return Returning{}; },
                      [](std::span<const uint64_t>) { return Returning{.owedBytes = 2 * room}; });
  require(governor.free(start, {.bytes = 2 * room}).outcome == FreeOutcome::Pending &&
              ledger.heldBytes(claim) == 2 * room,
          "the start did not wait holding its room");
  {
    const MemoryGovernor::Scope scope(governor, claim);
    require(refusal(kMiB) == metal::AllocationFailure::EngineBudget,
            "an allocation took the room a claim ranked above it holds");
    governor.fund(kMiB);
    require(refusal(kMiB) == metal::AllocationFailure::None,
            "the room a claim ranked above holds refused an allocation its scope's releases paid for");
  }
  ledger.close(start);
  ledger.close(claim);
}

// The host telemetry reads the task's footprint and compressed bytes, not its resident size, and the host's
// file-backed, inactive plus speculative and file cache pages, not its active ones; the snapshot carries it.
void testHostTelemetryReadsTheTaskAndTheHost() {
  task_vm_info_data_t task{};
  task.phys_footprint = 3 * kGiB;
  task.compressed = 256 * kMiB;
  task.resident_size = 5 * kGiB;
  vm_statistics64_data_t pages{};
  pages.external_page_count = 1000;
  pages.inactive_count = 300;
  pages.speculative_count = 20;
  pages.active_count = 999;
  pages.internal_page_count = 777;
  const HostTelemetry telemetry = hostTelemetryOf(task, pages, 400, 16384);
  require(telemetry.physFootprintBytes == 3 * kGiB && telemetry.compressedBytes == 256 * kMiB &&
              telemetry.fileBackedBytes == 1000 * 16384ULL && telemetry.inactiveBytes == 320 * 16384ULL &&
              telemetry.fileCacheMinimumBytes == 400 * 16384ULL,
          "the host telemetry did not read the task's footprint and compressed bytes and the host's file-backed, "
          "inactive and speculative pages and file cache minimum");
  // macOS sets the file cache minimum only once its pageout has run, so a freshly booted Mac reports 0.
  const std::optional<HostTelemetry> live = queryHostTelemetry();
  require(live && live->physFootprintBytes, "the live host telemetry is missing or has no footprint");
  test::metalStatistics() = {};
  metal::MetalBackend backend("unused");
  MemoryGovernor governor(backend, 4 * kGiB, kGiB, kGiB, [] { return hostMemory(8 * kGiB); }, 0);
  const std::optional<HostTelemetry> reported = governor.snapshot().hostTelemetry;
  require(reported && reported->physFootprintBytes, "the governor's snapshot did not carry the host telemetry");
}

// The exclusive resource-domain lease (T015/FR-005) over this governor: one
// holder at a time. The Owner thread's admissions and marks run; after a
// witnessed transfer, a callback captured BEFORE the transfer and every
// mutation from the former Owner thread are refused, while snapshot() stays
// a passive answer. The four witnesses here are fixtures for this fixture;
// the production receipts are owed to T016-T019 and claimed nowhere else.
void testResourceDomainAuthorityGovernsTheLedger() {
  static_assert(!std::is_copy_constructible_v<ResourceDomainLease>);
  static_assert(!std::is_copy_assignable_v<ResourceDomainLease>);
  static_assert(std::is_move_constructible_v<ResourceDomainLease>);
  static_assert(!std::is_copy_constructible_v<Quiescence>);
  static_assert(!std::is_copy_constructible_v<WorkerHandoff>);

  test::metalStatistics() = {};
  metal::MetalBackend backend("unused");
  const uint64_t hostReserve = 64 * 1024, limit = 64 * 1024;
  MemoryGovernor governor(backend, limit, hostReserve, hostReserve,
                          [] { return hostMemory(hostReserve + 3 * kGiB); }, 0);
  require(static_cast<bool>(admit(governor, 1024)),
          "an unbound governor changed its behavior");

  // Binding changes nothing for the Owner thread and nothing for readers.
  ResourceDomainLease lease = ResourceDomainLease::acquireForOwner();
  lease.attach(governor);
  lease.attach(backend);
  require(!lease.obtainQuiescence().has_value(),
          "authority could migrate before its quiescence witnesses existed");
  const auto captured = governor.allocationAdmission();  // captured now, below
  const ClaimId claimId = governor.ledger().open({.cls = ClaimClass::Floor});
  {
    const MemoryGovernor::Scope scope(governor, claimId);
    require(static_cast<bool>(captured(1024, [] { allocate(1024); })),
            "an authorized admission was refused while the Owner interval held");
    require(static_cast<bool>(captured(1024, [] {})), "a scoped second admission was refused");
  }
  governor.setPressure(MemoryPressure::Normal);
  require(governor.snapshot().limitBytes == limit, "the passive read moved");

  // Owner → Worker on a real second thread: the ledger keeps one writer,
  // deterministic signal pairs (no sleeps, no races as evidence).
  bool admissionReady = true;
  lease.setAdmissionWitness([&] { return admissionReady; });
  lease.setRequestDrainWitness([] { return true; });
  lease.setRetainedIoWitness([] { return true; });
  lease.setCallbackRetirementWitness([] { return true; });
  std::thread witnessIntruder([&] {
    rejects([&] { lease.setAdmissionWitness([] { return true; }); }, "does not hold",
            "non-Owner thread registered a witness");
  });
  witnessIntruder.join();
  auto stale = lease.obtainQuiescence();
  governor.setPressure(MemoryPressure::Normal);
  admissionReady = false;
  rejects([&] { (void)lease.transferToWorker(std::move(*stale)); }, "fresh quiescence",
          "Owner mutation left a proof usable");
  require(!lease.obtainQuiescence(), "proof reminted before quiescence was re-established");
  admissionReady = true;
  require(lease.obtainQuiescence().has_value(), "quiescent Owner stayed permanently blocked");
  auto registrationStale = lease.obtainQuiescence();
  lease.setAdmissionWitness([] { return true; });
  rejects([&] { (void)lease.transferToWorker(std::move(*registrationStale)); }, "fresh quiescence",
          "witness replacement left a proof usable");
  auto callbackStale = lease.obtainQuiescence();
  bool callbackRan = false;
  { const MemoryGovernor::Scope scope(governor, claimId);
    require(static_cast<bool>(captured(1, [&] {
    callbackRan = true;
    rejects([&] { (void)lease.transferToWorker(std::move(*callbackStale)); }, "fresh quiescence",
            "callback transferred authority with reservation outstanding");
    require(!lease.obtainQuiescence(), "proof minted during admission interval");
    })), "bounded callback admission failed");
  }
  governor.publishSnapshot();
  require(callbackRan && governor.snapshot().headroomBytes == limit - 1024,
          "reservation cleanup did not restore the ledger");
  // Reentrant witnesses cannot certify the state preceding their own mutation.
  lease.setAdmissionWitness([&] { governor.setPressure(MemoryPressure::Normal); return true; });
  require(!lease.obtainQuiescence(), "mutating witness minted a stale proof");
  lease.setAdmissionWitness([] { return true; });
  auto proof = lease.obtainQuiescence();
  require(proof.has_value(), "the fixture witnesses did not mint a proof");
  Quiescence moved(std::move(*proof));
  auto assignmentSource = lease.obtainQuiescence();
  moved = std::move(*assignmentSource);
  rejects([&] { (void)lease.transferToWorker(std::move(*assignmentSource)); }, "of this authority",
          "move-assigned source retained its proof");
  rejects([&] { (void)lease.transferToWorker(std::move(*proof)); }, "of this authority",
          "move-constructed source retained its proof");
  auto handoff = lease.transferToWorker(std::move(moved));
  require(lease.holder() == ResourceDomainAuthority::Holder::Worker,
          "transfer did not move the holder to Worker");

  rejects([&] { governor.setPressure(MemoryPressure::Warning); }, "resource-domain authority refused",
          "former Owner mutated governor before worker claim");
  rejects([&] { lease.returnToOwner(std::move(handoff)); }, "Parked",
          "unclaimed Worker returned directly to Owner");
  rejects([&] { (void)std::move(handoff).park(); }, "park() needs",
          "former Owner parked an unclaimed token");
  std::promise<WorkerHandoff *> claimed;
  auto claim = claimed.get_future();
  std::promise<void> probesDone;
  auto probesReady = probesDone.get_future();
  std::promise<WorkerHandoff> handedBack;
  auto handedBackToken = handedBack.get_future();
  std::string workerError;
  std::thread worker(
      [token = std::move(handoff), &governor, &captured, &claimed, &probesReady, claimId,
       &handedBack, &workerError]() mutable {
        try {
          token.claim();
          rejects([&] { token.claim(); }, "unclaimed", "worker token claimed twice");
          { const MemoryGovernor::Scope scope(governor, claimId);
            if (!captured(1024, [] { allocate(1024); }))
              throw std::runtime_error("the Worker interval refused its own admission");
          }
        } catch (const std::exception &error) {
          workerError = error.what();
        }
        claimed.set_value(&token);
        probesReady.wait();
          // Snapshot and mutation may overlap; ledger serialization, rather
          // than the worker pause below, protects every governor field.
          for (unsigned i = 0; i < 128; ++i)
            governor.setPressure(i & 1 ? MemoryPressure::Warning : MemoryPressure::Normal);
        governor.setPressure(MemoryPressure::Normal);
        handedBack.set_value(std::move(token).park());
      });
  auto *activeToken = claim.get();
  rejects([&] { lease.returnToOwner(std::move(*activeToken)); }, "Parked",
          "active Worker returned directly to Owner");
  rejects([&] { (void)std::move(*activeToken).park(); }, "park() needs",
          "former Owner parked the active worker token");
  rejects([&] { lease.setAdmissionWitness([] { return true; }); }, "does not hold",
          "former Owner replaced Worker witnesses");
  require(workerError.empty(), "the worker thread could not use the ledger: " + workerError);
  // This (former Owner) thread is now refused: the callback captured BEFORE
  // the transfer cannot mutate the ledger across holders...
  rejects([&] { (void)captured(1024, [] {}); }, "resource-domain authority refused",
          "a captured admission callback mutated the ledger from an unauthorized holder");
  rejects([&] { governor.setPressure(MemoryPressure::Warning); }, "resource-domain authority refused",
          "an unauthorized mutation marked the ledger");
  rejects([&] { (void)governor.evaluate(); }, "resource-domain authority refused",
          "the control pass bypassed the authority");
  // ...and yet every reader still answers, unchanged.
  require(governor.snapshot().limitBytes == limit &&
              governor.snapshot().deniedReservations == 0,
          "the passive read stopped answering beside a non-owner holder");
  probesDone.set_value();
  for (unsigned i = 0; i < 128; ++i)
    require(governor.snapshot().limitBytes == limit, "concurrent snapshot corrupted");
  worker.join();

  // Parked stays exclusive, then the Owner interval returns to this thread.
  auto tokenBack = handedBackToken.get();

  rejects([&] { (void)captured(1024, [] {}); }, "resource-domain authority refused",
          "parked authority let the ledger move");
  rejects([&] { governor.setPressure(MemoryPressure::Normal); }, "resource-domain authority refused",
          "parked authority marked the ledger");
  WorkerHandoff parkedMoved(std::move(tokenBack));
  rejects([&] { lease.returnToOwner(std::move(tokenBack)); }, "another resource domain",
          "moved-from parked token returned authority");
  ResourceDomainLease foreignOwner = ResourceDomainLease::acquireForOwner();
  rejects([&] { foreignOwner.returnToOwner(std::move(parkedMoved)); }, "another resource domain",
          "foreign return consumed the parked token");
  lease.returnToOwner(std::move(parkedMoved));
  rejects([&] { (void)lease.transferToWorker(std::move(moved)); }, "of this authority",
          "spent proof reactivated after return");
  rejects([&] { (void)lease.transferToWorker(std::move(*assignmentSource)); }, "of this authority",
          "moved-from proof reactivated after return");
  rejects([&] { (void)lease.transferToWorker(std::move(*stale)); }, "fresh quiescence",
          "old-generation proof reactivated after return");
  require(lease.holder() == ResourceDomainAuthority::Holder::Owner,
          "returnToOwner did not restore the Owner interval");
  { const MemoryGovernor::Scope scope(governor, claimId);
    require(static_cast<bool>(captured(1024, [] { allocate(1024); })) &&
                governor.snapshot().deniedReservations == 0 && governor.evaluate().hostMeasurementValid,
            "the returned Owner ledger refused its writer or its control pass");
  }
  governor.ledger().close(claimId);

  // Exactly one authority per domain: a second Owner lease refuses the bound
  // governor.
  ResourceDomainLease rival = ResourceDomainLease::acquireForOwner();
  rejects([&] { rival.attach(governor); }, "another resource domain",
          "a second Owner lease attached authority over the same governor");
}

// Assigning over a handle that still holds the authority is refused before
// either side is consumed. The discarded handle is what its destructor checks
// and what unbinds the surfaces the domain covers, so overwriting a live Owner
// handle would destroy its authority unseen and leave the governor and backend
// it attached ungated. Moving into an emptied handle stays supported.
void testAssigningOverALiveLeaseHandleRefuses() {
  static_assert(std::is_move_constructible_v<ResourceDomainLease>);
  static_assert(std::is_move_assignable_v<ResourceDomainLease>);
  static_assert(!std::is_nothrow_move_assignable_v<ResourceDomainLease>);

  test::metalStatistics() = {};
  metal::MetalBackend backend("unused");
  const uint64_t hostReserve = 64 * 1024, limit = 64 * 1024;
  MemoryGovernor governor(backend, limit, hostReserve, hostReserve,
                          [] { return hostMemory(hostReserve + 3 * kGiB); }, 0);
  ResourceDomainLease owner = ResourceDomainLease::acquireForOwner();
  owner.attach(governor);
  owner.attach(backend);
  ResourceDomainLease replacement = ResourceDomainLease::acquireForOwner();

  rejects([&] { owner = std::move(replacement); }, "move-assign over a handle",
          "assigning over a live Owner lease discarded its authority");
  // The refused assignment consumed neither authority: the old domain still
  // gates the governor it attached (this is the ungated-backend hole), and
  // the replacement handle still holds its own authority and is still refused
  // over the already-bound governor rather than reporting a dead handle.
  std::thread outsider([&] {
    rejects([&] { governor.setPressure(MemoryPressure::Normal); },
            "resource-domain authority refused",
            "the refused assignment unbound the governor the domain covers");
  });
  outsider.join();
  rejects([&] { replacement.attach(governor); }, "another resource domain",
          "the refused assignment emptied the replacement handle's authority");
  require(owner.holder() == ResourceDomainAuthority::Holder::Owner &&
              replacement.holder() == ResourceDomainAuthority::Holder::Owner,
          "assigning over a live handle moved a holder interval");
  require(static_cast<bool>(admit(governor, 1024, [] { allocate(1024); })),
          "the refused assignment left its owner unable to charge the ledger");

  // The same handle still accepts its legitimate moves: into an emptied handle
  // and out of it again, with the same authority and the same surfaces bound.
  ResourceDomainLease carried = std::move(owner);
  rejects([&] { carried = std::move(replacement); }, "move-assign over a handle",
          "the moved-to handle let itself be overwritten");
  owner = std::move(carried);
  require(owner.holder() == ResourceDomainAuthority::Holder::Owner &&
              replacement.holder() == ResourceDomainAuthority::Holder::Owner,
          "restoring a moved-from lease handle refused or misdirected the authority");
  require(governor.snapshot().limitBytes == limit &&
              governor.snapshot().headroomBytes == limit - 1024,
          "the moved handle stopped gating its surfaces");
}

// A live Worker or Parked token is the only handle on its interval: assigning
// over it would strand that interval with no way to claim, park or return it.
void testAssigningOverALiveWorkerTokenRefuses() {
  static_assert(!std::is_nothrow_move_assignable_v<WorkerHandoff>);

  ResourceDomainLease left = ResourceDomainLease::acquireForOwner();
  ResourceDomainLease right = ResourceDomainLease::acquireForOwner();
  for (ResourceDomainLease *handle : {&left, &right}) {
    handle->setAdmissionWitness([] { return true; });
    handle->setRequestDrainWitness([] { return true; });
    handle->setRetainedIoWitness([] { return true; });
    handle->setCallbackRetirementWitness([] { return true; });
  }
  auto leftToken = left.transferToWorker(std::move(*left.obtainQuiescence()));
  auto rightToken = right.transferToWorker(std::move(*right.obtainQuiescence()));
  require(left.holder() == ResourceDomainAuthority::Holder::Worker &&
              right.holder() == ResourceDomainAuthority::Holder::Worker,
          "the fixture handoffs did not move both authorities to Worker");

  rejects([&] { leftToken = std::move(rightToken); }, "still holds authority",
          "assigning over a live worker token orphaned its Worker interval");
  // The Owner-side handle of a Worker interval is live too: overwriting it
  // would leave the token's interval with no owner to return it to.
  rejects([&] { left = std::move(right); }, "move-assign over a handle",
          "assigning over a Worker-interval lease handle orphaned that domain");
  require(leftToken.holder() == ResourceDomainAuthority::Holder::Worker &&
              rightToken.holder() == ResourceDomainAuthority::Holder::Worker,
          "the refused assignments consumed or moved a token");

  // Both domains still complete their round trips: claim, park, return.
  leftToken.claim();
  rightToken.claim();
  auto parkedLeft = std::move(leftToken).park();
  auto parkedRight = std::move(rightToken).park();
  rejects([&] { parkedLeft = std::move(parkedRight); }, "still holds authority",
          "assigning over a parked token stranded the Parked interval");
  WorkerHandoff restored = std::move(parkedLeft);
  parkedLeft = std::move(restored);
  left.returnToOwner(std::move(parkedLeft));
  right.returnToOwner(std::move(parkedRight));
  require(left.holder() == ResourceDomainAuthority::Holder::Owner &&
              right.holder() == ResourceDomainAuthority::Holder::Owner,
          "the refused assignments did not leave both authorities returnable");
}

} // namespace

int main() {
  try {
    testHostAvailabilityCountsReclaimablePages();
    testAdvertisedContextIsGrantable();
    testReservationsAndAdmissionClasses();
    testHostHeldBytesAreCharged();
    testHostRefusalComesBeforeTheEngineLimit();
    testAnAllocationOutsideAClaimThrows();
    testReleasedBytesPayOnlyForTheirScope();
    testEssentialClaimScopeRestoresAdmissionPolicy();
    testReleasedBytesPayPastTheLimitAndTheHeldRoom();
    testResourceDomainAuthorityGovernsTheLedger();
    testAssigningOverALiveLeaseHandleRefuses();
    testAssigningOverALiveWorkerTokenRefuses();
    testHostTelemetryReadsTheTaskAndTheHost();
    std::cout << "memory governor tests passed\n";
    return EXIT_SUCCESS;
  } catch (const std::exception &error) {
    std::cerr << "memory governor tests failed: " << error.what() << '\n';
    return EXIT_FAILURE;
  }
}
