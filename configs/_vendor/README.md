# FreeCM command validator

The MIT-licensed command manifest validator and JSONC helpers are copied unchanged
from XTouchCompactDev's `configs/_vendor/`, which took them from BCR2000Dev's
FreeCM 0.1.156 snapshot. `UPSTREAM.json` records the FreeCM revision, original
hashes and namespace changes; `LICENSE` preserves its license notice. In this
repository the package is imported as `_vendor.freecm` with `configs/` on the path.
No FreeCM checkout, dependency lock or runtime integration is required, and no
Swift target uses these helpers.
