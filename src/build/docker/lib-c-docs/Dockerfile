#--------------------------------------------------------------------
# Generate documentation with Doxygen
#--------------------------------------------------------------------
FROM ubuntu:24.04 AS builder

# Build argument for noindex header
ARG ADD_NOINDEX_HEADER=false
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

# Pass build arg to runtime stage
ARG ADD_NOINDEX_HEADER=false
ENV ADD_NOINDEX_HEADER=$ADD_NOINDEX_HEADER

# Copy documentation
COPY --from=builder /ghostty/zig-out/share/ghostty/doc/libghostty /usr/share/nginx/html

# Create entrypoint script
RUN cat > /entrypoint.sh << 'EOF'
#!/bin/sh
if [ "$ADD_NOINDEX_HEADER" = "true" ]; then
    cat > /etc/nginx/conf.d/noindex.conf << 'INNER_EOF'
server {
    listen 80;
    location / {
        root /usr/share/nginx/html;
        index index.html;
        add_header X-Robots-Tag "noindex, nofollow" always;
    }
}
INNER_EOF

    # Remove default server config
    rm -f /etc/nginx/conf.d/default.conf
fi
exec nginx -g "daemon off;"
EOF

RUN chmod +x /entrypoint.sh

EXPOSE 80
CMD ["/entrypoint.sh"]
