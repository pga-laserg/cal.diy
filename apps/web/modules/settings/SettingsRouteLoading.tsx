"use client";

import SettingsHeader from "@calcom/features/settings/appDir/SettingsHeader";
import { SkeletonContainer, SkeletonText } from "@calcom/ui/components/skeleton";

export default function SettingsRouteLoading() {
  return (
    <SettingsHeader borderInShellHeader={true}>
      <SkeletonContainer>
        <div className="border-subtle stack-y-4 rounded-b-lg border border-t-0 px-6 py-5">
          <SkeletonText className="h-7 w-full" />
          <SkeletonText className="h-7 w-4/5" />
          <SkeletonText className="h-7 w-3/5" />
        </div>
      </SkeletonContainer>
    </SettingsHeader>
  );
}
