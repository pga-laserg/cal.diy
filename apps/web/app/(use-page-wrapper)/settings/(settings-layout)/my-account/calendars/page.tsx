import { _generateMetadata } from "app/_utils";

import { CalendarListContainer } from "@components/apps/CalendarListContainer";

export const generateMetadata = async () =>
  await _generateMetadata(
    (t) => t("calendars"),
    (t) => t("calendars_description"),
    undefined,
    undefined,
    "/settings/my-account/calendars"
  );

const Page = () => {
  // Calendar provider sync happens after the settings shell has rendered.
  return <CalendarListContainer />;
};

export default Page;
