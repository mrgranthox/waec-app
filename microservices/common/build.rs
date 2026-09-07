//! Build script: compiles protobuf contracts (proto/) into Rust using
//! the pure-Rust protox compiler — no protoc binary required.

use std::path::PathBuf;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let proto_root = PathBuf::from("../proto");
    let protos = [
        "waec/common/v1/common.proto",
        "waec/auth/v1/auth.proto",
        "waec/payment/v1/payment.proto",
        "waec/distributor/v1/distributor.proto",
        "waec/handler/v1/handler.proto",
        "waec/admin/v1/admin.proto",
    ];

    let file_descriptors = protox::compile(
        protos.iter().map(|p| proto_root.join(p)),
        [proto_root.clone()],
    )?;

    let out_dir = PathBuf::from(std::env::var("OUT_DIR")?);

    // Generate message types + gRPC clients/servers from the compiled
    // descriptor set in one pass.
    tonic_build::configure()
        .build_server(true)
        .build_client(true)
        .out_dir(out_dir.clone())
        .compile_fds(file_descriptors)?;

    for p in &protos {
        println!("cargo:rerun-if-changed={}", proto_root.join(p).display());
    }
    Ok(())
}
