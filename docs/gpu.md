# The GPU path

> **Untested.** I do not own an NVIDIA GPU, and nothing on this page has run on real
> hardware. CI checks only that `compose.gpu.yaml` renders. Everything the rest of this
> repository claims is measured on a CPU-only machine. Treat this page as a starting
> point that needs its own testing, not as a supported configuration.

## What changes

`compose.gpu.yaml` is an override. It reserves the host's NVIDIA GPUs for the Ollama
container, raises its memory limit, and allows two requests in parallel.

```bash
docker compose -f compose.yaml -f compose.gpu.yaml up -d
```

Nothing else in the stack changes: the gateway, SSO, backups, drill and smoke test
are identical. That is deliberate. The GPU should be a capacity change, not a second
architecture to keep working.

## Host prerequisites

1. An NVIDIA driver recent enough for the CUDA version bundled in the pinned Ollama image.
2. The NVIDIA Container Toolkit, with Docker configured to use it
   (`nvidia-ctk runtime configure --runtime=docker`, then restart Docker).
3. `docker run --rm --gpus all ubuntu nvidia-smi` shows the GPU. If this fails, nothing
   in this repository will fix it.

## How to know it is actually using the GPU

Ollama falls back to CPU silently when it cannot use the GPU. The stack will be up,
healthy and passing the smoke test, just slow. After a request:

```bash
docker compose exec ollama ollama ps
```

The `PROCESSOR` column should say `100% GPU`. Anything with `CPU` in it means the
model, or part of it, did not fit in VRAM or the GPU was not visible.

A GPU deployment should add that check to `smoke_test.sh`, so a host that loses its GPU
fails the deploy instead of running at CPU speed unnoticed. It is not in the smoke test
now because CI has no GPU to run it on.

## Model choice with a GPU

The reason to have a GPU is usually a larger model. Change `config/models.lock` in a
pull request. Rough VRAM needs at 4-bit quantisation with an 8k context: about 1 GB per
billion parameters plus 1 to 2 GB for the context. These figures are from published
model sizes, not from measurement here.

## AMD

Ollama publishes `-rocm` image tags for AMD GPUs. That path uses different device
mappings (`/dev/kfd`, `/dev/dri`) and a different image, so it would be a separate
override file. Also untested.
