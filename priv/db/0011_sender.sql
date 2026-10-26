-- sender (docs/mail/sender.md): an email mission's sender, the domain address,
-- and no send cap of hireme's own. Written by hand: dropping daily_cap is a step
-- the generator cannot add.
ALTER TABLE "mailboxes" DROP COLUMN "daily_cap";
ALTER TABLE "mailboxes" ADD COLUMN "domain_from" TEXT;
ALTER TABLE "missions" ADD COLUMN "sender" TEXT NOT NULL DEFAULT 'gmail';
