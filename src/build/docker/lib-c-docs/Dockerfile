#--------------------------------------------------------------------
# Generate documentation with Doxygen
#--------------------------------------------------------------------
FROM ubuntu:24.04 AS builder
RUN apt-get update && apt-get install -y \
    doxygen \
    graphviz \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /ghostty
COPY include/ ./include/
COPY Doxyfile ./
RUN mkdir -p zig-out/share/ghostty/doc/libghostty
RUN doxygen

#--------------------------------------------------------------------
# Host the static HTML
#--------------------------------------------------------------------
FROM nginx:alpine AS runtime
COPY --from=builder /ghostty/zig-out/share/ghostty/doc/libghostty /usr/share/nginx/html
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
