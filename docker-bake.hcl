# Local and CI build graph. Three image roles (docs/images.md):
#
#   product   dev-base/Dockerfile.<variant>       published release artifact
#   test      tests/product/Dockerfile.<variant>  product + smoke-test scripts only
#   extras    extras/Dockerfile.<variant>         product + repo dev tools
#                                                 (devcontainer / CI checks); not published
#
# `test` and `extras` are built FROM the product built from this checkout, via
# named build contexts, so the product image is never modified.
#
#   docker buildx bake --load                          # debian: product, test, extras
#   VARIANT=alpine docker buildx bake --load
#   docker buildx bake product --set product.tags=ghcr.io/ivan-kostko/dev-base:debian --load
#     # -> lets the devcontainer (which builds extras on the published tag) use local product changes

variable "VARIANT" {
  default = "debian"
}

variable "PLATFORMS" {
  default = "linux/amd64"
}

# Mutable upstream inputs. CI resolves them (scripts/resolve-upstream-versions.sh)
# and passes explicit values so they are recorded; empty = upstream latest.
variable "CLAUDE_CODE_VERSION" {
  default = ""
}
variable "CODEX_VERSION" {
  default = ""
}
variable "OMZ_REF" {
  default = ""
}
variable "P10K_REF" {
  default = ""
}

# Set to a pushed product reference (registry/name@sha256:...) to build the
# test image on it instead of the local product ("test-published").
variable "PRODUCT_REF" {
  default = ""
}

target "product" {
  context    = "dev-base"
  dockerfile = "Dockerfile.${VARIANT}"
  args = {
    CLAUDE_CODE_VERSION = CLAUDE_CODE_VERSION
    CODEX_VERSION       = CODEX_VERSION
    OMZ_REF             = OMZ_REF
    P10K_REF            = P10K_REF
  }
  platforms = split(",", PLATFORMS)
  tags      = ["dev-base-product:${VARIANT}"]
}

target "_derived" {
  context   = "."
  platforms = split(",", PLATFORMS)
}

target "test" {
  inherits   = ["_derived"]
  dockerfile = "tests/product/Dockerfile.${VARIANT}"
  contexts   = { product = "target:product" }
  args       = { PRODUCT_IMAGE = "product" }
  tags       = ["dev-base-test:${VARIANT}"]
}

target "test-published" {
  inherits   = ["_derived"]
  dockerfile = "tests/product/Dockerfile.${VARIANT}"
  args       = { PRODUCT_IMAGE = PRODUCT_REF }
  tags       = ["dev-base-test:${VARIANT}"]
}

target "extras" {
  inherits   = ["_derived"]
  dockerfile = "extras/Dockerfile.${VARIANT}"
  contexts   = { product = "target:product" }
  args       = { BASE_IMAGE = "product" }
  tags       = ["dev-base-extras:${VARIANT}"]
}

group "default" {
  targets = ["product", "test", "extras"]
}
