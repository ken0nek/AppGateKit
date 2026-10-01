// AppGateClient holds the code with side effects: both fetches, both last-good
// caches, the TTLs, the clock-skew guard, the dismissal and the DEBUG
// overrides.
//
// It makes every decision by calling AppGateCore and repeats no precedence or
// version-comparison logic. What it adds is the caching rules. A mistake in
// those either keeps a wall up after its floor is gone or keeps enforcing a
// rule after the site that served it is unreachable.
