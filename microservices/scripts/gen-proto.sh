#!/usr/bin/env bash
# Generates Rust code from protobuf contracts (single source of truth).
# Requires: protoc, buf (https://buf.build) OR falls back to tonic-build via protohacker.
set -euo pipefail

cd "$(dirname "$0")"

if ! command -v protoc >/dev/null 2>&1; then
  echo "ERROR: protoc not found. Install with: sudo apt install -y protobuf-compiler" >&2
  exit 1
fi

echo "Generating Rust code from proto/ ..."
protoc \
  --proto_path=proto \
  --descriptor_set_out=common/src/pb_descriptor.bin \
  --include_imports \
  proto/waec/common/v1/common.proto \
  proto/waec/auth/v1/auth.proto \
  proto/waec/payment/v1/payment.proto \
  proto/waec/distributor/v1/distributor.proto \
  proto/waec/handler/v1/handler.proto \
  proto/waec/admin/v1/admin.proto

echo "PROTO_GEN_OK: common/src/pb_descriptor.bin"
