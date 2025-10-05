#--------------------------------------------------------------------
# Build Doxygen from source
#--------------------------------------------------------------------
FROM ubuntu:24.04 AS doxygen-builder

ARG DOXYGEN_VERSION=1.14.0
RUN apt-get update && apt-get install -y \
    wget \
    cmake \
    g++ \
    flex \
    bison \
    python3 \
    && rm -rf /var/lib/apt/lists/* \
    && wget -q https://www.doxygen.nl/files/doxygen-${DOXYGEN_VERSION}.src.tar.gz \
    && tar -xzf doxygen-${DOXYGEN_VERSION}.src.tar.gz \
    && cd doxygen-${DOXYGEN_VERSION} \
    && cmake -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Release \
    && make -j$(nproc) \
    && make install \
    && cd .. \
    && rm -rf doxygen-${DOXYGEN_VERSION}*

#--------------------------------------------------------------------
# Generate documentation with Doxygen
#--------------------------------------------------------------------
FROM ubuntu:24.04 AS builder

# Build argument for noindex header
ARG ADD_NOINDEX_HEADER=false
RUN apt-get update && apt-get install -y \
    graphviz \
    && rm -rf /var/lib/apt/lists/*
COPY --from=doxygen-builder /usr/local/bin/doxygen /usr/local/bin/doxygen
WORKDIR /ghostty
COPY include/ ./include/
COPY Doxyfile ./
RUN mkdir -p zig-out/share/ghostty/doc/libghostty
RUN doxygen

#--------------------------------------------------------------------
# Host the static HTML
#--------------------------------------------------------------------
FROM nginx:alpine AS runtime

# Pass build arg to runtime stage
ARG ADD_NOINDEX_HEADER=false
ENV ADD_NOINDEX_HEADER=$ADD_NOINDEX_HEADER

# Copy documentation and entrypoint script
COPY --from=builder /ghostty/zig-out/share/ghostty/doc/libghostty /usr/share/nginx/html
COPY src/build/docker/lib-c-docs/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 80
CMD ["/entrypoint.sh"]
