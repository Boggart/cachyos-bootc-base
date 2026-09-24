# Create an output folder on your host machine to catch the file
mkdir -p ./dist

podman run --rm -it \
  --device /dev/fuse \
  --security-opt label=disable \
  --security-opt unmask=ALL \
  -v .:/workspace:Z \
  -w /workspace \
  quay.io/buildah/stable:latest \
  sh -c "buildah build --skip-unused-stages=false -f Containerfile -t cachyos-bootc:chunked . && \
         buildah push cachyos-bootc:chunked oci-archive:./dist/cachyos-base.tar"
