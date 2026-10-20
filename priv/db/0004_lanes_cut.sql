-- lanes_cut: the Lanes lens goes, and with it its tables, its settings and
-- its domain. Hand-written: the drops, then every key's masks rewritten for
-- the domains that remain (lanes was bit 8; corpus moves from 16 to 8).
DROP TABLE "gym_reps";
DROP TABLE "net_entries";
ALTER TABLE "settings" DROP COLUMN "gym_target";
ALTER TABLE "settings" DROP COLUMN "net_lane_url";
UPDATE "api_keys" SET
  "read_mask" = ("read_mask" & 7) | (("read_mask" & 16) >> 1),
  "write_mask" = ("write_mask" & 7) | (("write_mask" & 16) >> 1);
