"use client";

import { useWebPush } from "@calcom/web/modules/notifications/hooks/useWebPush";
import SettingsHeader from "@calcom/features/settings/appDir/SettingsHeader";
import { useLocale } from "@calcom/lib/hooks/useLocale";
import { Alert } from "@calcom/ui/components/alert";
import { Button } from "@calcom/ui/components/button";

const PushNotificationsView = () => {
  const { t } = useLocale();
  const { subscribe, unsubscribe, isSubscribed, isLoading, isSupported, hasSetupError } = useWebPush();

  return (
    <SettingsHeader
      title={t("push_notifications")}
      description={t("push_notifications_description")}
      borderInShellHeader={true}>
      <div className="border-subtle rounded-b-xl border-x border-b px-4 pb-10 pt-8 sm:px-6">
        {(!isSupported || hasSetupError) && (
          <Alert severity="warning" className="mb-4" message={t("something_went_wrong")} />
        )}
        <Button
          color="primary"
          onClick={isSubscribed ? unsubscribe : subscribe}
          disabled={isLoading || !isSupported || hasSetupError}>
          {isSubscribed ? t("disable_browser_notifications") : t("allow_browser_notifications")}
        </Button>
      </div>
    </SettingsHeader>
  );
};

export default PushNotificationsView;
