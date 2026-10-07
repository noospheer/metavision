# vrapi

The legacy Oculus Mobile SDK runtime, mapped onto CompositorServices.

Upstream Klepton implements OpenXR and does not implement VrApi, so this is the
piece that unlocks the older catalogue: everything built against VrApi
before Meta's OpenXR migration, including UE4 titles and native engine ports.

Naming follows upstream's `kl_` convention so these files drop into
`runtime/xr/` cleanly if they are ever upstreamed.

## Headers: declared, not vendored

Meta published `VrApi_Types.h` in the Oculus Mobile SDK under a proprietary
licence, so it is not redistributable here. The ABI is declared from the public
API documentation instead.

That trade has a known cost: **a wrong struct layout is silent.** A field at the
wrong offset does not fail, it reads a neighbouring value, and the symptom
surfaces somewhere unrelated — a pose that drifts, a swapchain index that walks
off the end. Debugging that from the outside is brutal.

So the layout is not trusted. It is checked, three ways:

### 1. Ground truth from the binary, not from memory

`tools/metavision-vrapi-abi` derives real offsets from a `libvrapi.so` the user
already has — the same approach as upstream's `tools/ovrp_abi.py`, which exists
because this class of bug cost that project two separate debugging arcs. It
emits `vrapi_abi_expect.h`, and the declarations here static-assert against it.
Drift becomes a compile error rather than a mystery.

Without a `libvrapi.so` in the tree the asserts compile out, and the header says
so loudly rather than pretending it verified something.

### 2. Structure tags, checked on every call

Every VrApi parms struct carries an `ovrStructureType` as its first member and
every layer an `ovrLayerType2`. Both are validated on entry. A mismatch aborts
naming the function and the tag it actually saw, which localises a layout error
to one call instead of one process.

### 3. Unimplemented entry points abort by name

Never a null jump. A title reaching an unimplemented function should produce a
line naming it, because that name is the entire bug report.
