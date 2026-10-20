-- atlas: the atlas reads every place for the person. me gains the permits
-- held, the countries wanted or never wanted, notes for agents and the
-- weights (a recipe over any figure of places); the seven fixed weights, the
-- chart columns of places and the atlas projection go. Written by hand: a
-- dropped column is no additive step. The dropped ids are retired in
-- schema/hireme.schema, so no id moves.
ALTER TABLE "me" ADD COLUMN "work_permits" TEXT;
ALTER TABLE "me" ADD COLUMN "prefer" TEXT;
ALTER TABLE "me" ADD COLUMN "avoid" TEXT;
ALTER TABLE "me" ADD COLUMN "notes" TEXT;
ALTER TABLE "me" ADD COLUMN "weights" TEXT;
ALTER TABLE "me" DROP COLUMN "w_energy";
ALTER TABLE "me" DROP COLUMN "w_economy";
ALTER TABLE "me" DROP COLUMN "w_liveability";
ALTER TABLE "me" DROP COLUMN "w_mobility";
ALTER TABLE "me" DROP COLUMN "w_language";
ALTER TABLE "me" DROP COLUMN "w_tech";
ALTER TABLE "me" DROP COLUMN "w_ease";
ALTER TABLE "places" DROP COLUMN "atlas_position";
ALTER TABLE "places" DROP COLUMN "atlas_labeled";
