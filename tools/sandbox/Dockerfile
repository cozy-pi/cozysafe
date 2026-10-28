# The container tools/sandbox runs Rust builds in (docs/supply-chain.md, "Builds on a
# person's computer"): the official Rust image at the toolchain of rust-toolchain.toml,
# pinned by digest, plus the two components that toolchain file asks for.
FROM rust:1.99.1-slim@sha256:b8e062b1c3a80183df83d9ba187cadd2b5ab84bc78d453dbfeb2fccd5f982247
RUN rustup component add clippy rustfmt \
 && useradd --create-home --uid 1000 builder \
 && mkdir /cargo /target && chown builder /cargo /target
USER builder
ENV CARGO_HOME=/cargo CARGO_TARGET_DIR=/target
