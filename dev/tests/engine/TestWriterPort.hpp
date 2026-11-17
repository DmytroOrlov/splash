#pragma once

#include "engine/ResourceDomainLease.hpp"
#include "model/WeightMemory.hpp"

struct TestWriterPort final : splash::model::WriterRetirementPort {
  splash::engine::ResourceDomainLease &lease;
  splash::engine::WriterRetirement &receipt;
  TestWriterPort(splash::engine::ResourceDomainLease &l, splash::engine::WriterRetirement &r) : lease(l), receipt(r) {}
  void launch(std::function<void()> body) override { receipt.launch(std::move(body)); }
  bool joined() const override { return receipt.joined(); }
  void reclaim() override { lease.reclaimWriter(receipt); }
  std::exception_ptr failure() const override { return receipt.failure(); }
};
