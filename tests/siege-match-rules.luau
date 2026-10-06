local rules = require("../src/shared/SiegeMatchRules")

assert(rules.REGULATION_SECONDS == 780)
assert(rules.OVERTIME_SECONDS == 120)
assert(rules.VAULT_MAX_HEALTH == 750)
assert(rules.KEEP_OVERTIME_MAX_HEALTH == 900)

assert(rules.winnerAtCap(400, 100, 399, 900) == 1)
assert(rules.winnerAtCap(399, 900, 400, 100) == 2)
assert(rules.winnerAtCap(400, 200, 400, 100) == 1)
assert(rules.winnerAtCap(400, 100, 400, 200) == 2)
assert(rules.winnerAtCap(400, 200, 400, 200) == 0)

print("Siege match rules passed")
