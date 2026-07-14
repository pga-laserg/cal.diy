import { _generateMetadata } from "app/_utils";

import { ConferencingAppsViewWebWrapper } from "@calcom/web/modules/apps/components/ConferencingAppsViewWebWrapper";

export const generateMetadata = async () =>
  await _generateMetadata(
    (t) => t("conferencing"),
    (t) => t("conferencing_description"),
    undefined,
    undefined,
    "/settings/my-account/conferencing"
  );

const Page = () => {
  // The installed app list and event types are loaded inside the page so navigation stays responsive.
  return <ConferencingAppsViewWebWrapper />;
};

export default Page;
