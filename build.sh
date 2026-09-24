# Create an output folder on your host machine to catch the file
mkdir -p ./dist

podman run --rm -it \
  --device /dev/fuse \
  --security-opt label=disable \
  --security-opt unmask=ALL \
  -v "$(pwd):/run/src:Z" \
  -w /run/src \
  quay.io/buildah/stable:latest \
  sh -euxc '
    buildah build \
      --skip-unused-stages=false \
      -f Containerfile \
      -t localhost/cachyos-bootc:chunked \
      .

    buildah push \
      localhost/cachyos-bootc:chunked \
      oci-archive:/run/src/dist/cachyos-base.tar
  '
