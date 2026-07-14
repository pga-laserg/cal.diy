"use client";

import SettingsRouteError from "~/settings/SettingsRouteError";

export default function Error({ reset }: { error: Error & { digest?: string }; reset: () => void }) {
  return <SettingsRouteError reset={reset} />;
}
