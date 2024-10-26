# Build arguments
ARG IMAGE_TYPE=extras
ARG BASE_IMAGE=ubuntu:22.04
ARG GRPC_BASE_IMAGE=${BASE_IMAGE}
ARG BUILD_TYPE=cpu
ARG FFMPEG=true
ARG GO_VERSION=1.22.6
ARG CMAKE_VERSION=3.26.4
ARG TARGETARCH=arm64
ARG EXTRA_BACKENDS="coqui bark parler-tts piper"
ARG GRPC_MAKEFLAGS="-j1 -Otarget"
ARG MAKEFLAGS="-j1"
ARG LD_FLAGS="-s -w"

FROM ${BASE_IMAGE} AS requirements-core

USER root

ENV DEBIAN_FRONTEND=noninteractive
# Updated EXTERNAL_GRPC_BACKENDS to include piper
ENV EXTERNAL_GRPC_BACKENDS="coqui:/build/backend/python/coqui/run.sh,bark:/build/backend/python/bark/run.sh,parler-tts:/build/backend/python/parler-tts/run.sh,piper:/build/backend/python/piper/run.sh"

# Install basic requirements
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential \
        ccache \
        ca-certificates \
        curl libssl-dev \
        git \
        unzip upx-ucl \
        cmake && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Install Go - explicitly for arm64
RUN curl -L -s https://go.dev/dl/go1.22.6.linux-arm64.tar.gz -o go.tar.gz && \
    tar -C /usr/local -xzf go.tar.gz && \
    rm go.tar.gz

ENV PATH=$PATH:/root/go/bin:/usr/local/go/bin

# Install grpc compilers
RUN go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.34.2 && \
    go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@1958fcbe2ca8bd93af633f11e97d44e567e945af

# Requirements for TTS backends
FROM requirements-core AS requirements-extras

RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.cargo/bin:${PATH}"

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        espeak-ng \
        espeak \
        python3-pip \
        python-is-python3 \
        python3-dev \
        llvm \
        python3-venv \
        ffmpeg && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    pip install --upgrade pip

# Install grpcio-tools
RUN pip install --user grpcio-tools

# GRPC installation
FROM ${BASE_IMAGE} AS grpc

ARG GRPC_MAKEFLAGS="-j1 -Otarget"
ARG GRPC_VERSION=v1.65.0

ENV MAKEFLAGS=${GRPC_MAKEFLAGS}

WORKDIR /build

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        build-essential \
        curl \
        libssl-dev \
        git \
        cmake && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

RUN git clone --recurse-submodules --jobs 1 -b ${GRPC_VERSION} --depth 1 --shallow-submodules https://github.com/grpc/grpc && \
    mkdir -p /build/grpc/cmake/build && \
    cd /build/grpc/cmake/build && \
    sed -i "216i\  TESTONLY" "../../third_party/abseil-cpp/absl/container/CMakeLists.txt" && \
    cmake -DgRPC_INSTALL=ON -DgRPC_BUILD_TESTS=OFF -DCMAKE_INSTALL_PREFIX:PATH=/opt/grpc ../.. && \
    make && \
    make install && \
    rm -rf /build

# Final image
FROM requirements-extras

ARG GO_TAGS="tts"
ARG MAKEFLAGS="-j1"
ENV GO_TAGS=${GO_TAGS}
ENV MAKEFLAGS=${MAKEFLAGS}
ENV REBUILD=false
ENV HEALTHCHECK_ENDPOINT=http://localhost:8080/readyz

WORKDIR /build

# Copy the source code
COPY . .
COPY --from=grpc /opt/grpc /usr/local

# Prepare and build specific backends
RUN make prepare-sources && \
    make prepare

# Build only the TTS backends you need
RUN if [[ "${EXTRA_BACKENDS}" =~ "coqui" ]]; then \
        make -C backend/python/coqui \
    ; fi && \
    if [[ "${EXTRA_BACKENDS}" =~ "bark" ]]; then \
        make -C backend/python/bark \
    ; fi && \
    if [[ "${EXTRA_BACKENDS}" =~ "parler-tts" ]]; then \
        make -C backend/python/parler-tts \
    ; fi && \
    if [[ "${EXTRA_BACKENDS}" =~ "piper" ]]; then \
        make -C backend/python/piper \
    ; fi

# Create directory for piper libraries and ensure it exists
RUN mkdir -p /build/sources/go-piper/piper-phonemize/pi/lib/ && \
    mkdir -p /usr/lib/

# Build the main binary
RUN make build

# Create models directory
RUN mkdir -p /build/models

# Health check
HEALTHCHECK --interval=1m --timeout=10m --retries=10 \
  CMD curl -f ${HEALTHCHECK_ENDPOINT} || exit 1

VOLUME /build/models
EXPOSE 8080
ENTRYPOINT [ "/build/entrypoint.sh" ]