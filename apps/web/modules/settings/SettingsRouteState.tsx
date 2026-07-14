"use client";

import { usePathname } from "next/navigation";
import { useEffect } from "react";

const NAVIGATION_STORAGE_KEY = "caldiy:settings-navigation";
const SLOW_NAVIGATION_MS = 2000;

type PendingNavigation = {
  pathname: string;
  startedAt: number;
};

function readPendingNavigation(): PendingNavigation | null {
  try {
    const value = window.sessionStorage.getItem(NAVIGATION_STORAGE_KEY);
    return value ? (JSON.parse(value) as PendingNavigation) : null;
  } catch {
    return null;
  }
}

export function SettingsNavigationMonitor() {
  const pathname = usePathname();

  useEffect(() => {
    const onClick = (event: MouseEvent) => {
      const link = (event.target as Element | null)?.closest<HTMLAnchorElement>(
        'a[data-testid^="vertical-tab-"]'
      );
      if (!link || link.target === "_blank") return;

      const destination = new URL(link.href, window.location.origin);
      if (!destination.pathname.startsWith("/settings/")) return;

      window.performance.mark(`caldiy:settings:start:${destination.pathname}`);
      window.sessionStorage.setItem(
        NAVIGATION_STORAGE_KEY,
        JSON.stringify({ pathname: destination.pathname, startedAt: window.performance.now() })
      );
    };

    document.addEventListener("click", onClick, true);
    return () => document.removeEventListener("click", onClick, true);
  }, []);

  useEffect(() => {
    if (!pathname?.startsWith("/settings/")) return;

    const navigation = readPendingNavigation();
    if (!navigation || navigation.pathname !== pathname) return;

    const durationMs = Math.round(window.performance.now() - navigation.startedAt);
    window.performance.mark(`caldiy:settings:end:${pathname}`);
    window.performance.measure(`caldiy:settings:${pathname}`, {
      start: navigation.startedAt,
      end: window.performance.now(),
    });
    window.sessionStorage.removeItem(NAVIGATION_STORAGE_KEY);
    window.dispatchEvent(new CustomEvent("caldiy:settings-navigation", { detail: { pathname, durationMs } }));

    if (durationMs >= SLOW_NAVIGATION_MS) {
      console.warn("Slow settings navigation", { pathname, durationMs });
    }
  }, [pathname]);

  return null;
}

export function SettingsPageReadyMarker() {
  const pathname = usePathname();

  return <span data-testid="settings-page-ready" data-pathname={pathname ?? ""} className="sr-only" />;
}
