"use client";

import SettingsHeader from "@calcom/features/settings/appDir/SettingsHeader";
import { useLocale } from "@calcom/lib/hooks/useLocale";
import { Button } from "@calcom/ui/components/button";

export default function SettingsRouteError({ reset }: { reset: () => void }) {
  const { t } = useLocale();

  return (
    <SettingsHeader title={t("something_went_wrong")} description={t("try_again")} borderInShellHeader={true}>
      <div className="border-subtle rounded-b-lg border border-t-0 px-6 py-5">
        <Button color="secondary" onClick={reset}>
          {t("retry")}
        </Button>
      </div>
    </SettingsHeader>
  );
}
