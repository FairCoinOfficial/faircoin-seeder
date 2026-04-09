# syntax=docker/dockerfile:1.6

# ---------- build stage ----------
FROM ubuntu:22.04 AS build

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        libboost-all-dev \
        libssl-dev \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY . .

# Build with portable flags so the resulting binary can run on any amd64 host.
RUN make clean 2>/dev/null || true \
    && make CXXFLAGS="-O2 -g0 -pthread" LDFLAGS="-O2 -g0 -pthread"

# ---------- runtime stage ----------
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libssl3 \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /var/lib/dnsseed

COPY --from=build /src/dnsseed /usr/local/bin/dnsseed

WORKDIR /var/lib/dnsseed

EXPOSE 53/udp
EXPOSE 53/tcp

ENTRYPOINT ["/usr/local/bin/dnsseed"]
