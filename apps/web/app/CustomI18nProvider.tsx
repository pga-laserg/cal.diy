"use client";

import { createInstance } from "i18next";
import { I18nextProvider, initReactI18next } from "react-i18next";
import { createContext, useMemo } from "react";
import type { ReactNode } from "react";

type CustomI18nContextType = {
  translations: Record<string, string>;
  ns: string;
  locale: string;
};

export const CustomI18nContext = createContext<CustomI18nContextType | null>(null);

export function CustomI18nProvider({
  children,
  translations,
  locale,
  ns,
}: CustomI18nContextType & {
  children: ReactNode;
}) {
  // Memoize the value to prevent re-renders unless the data changes
  const value = useMemo(
    () => ({
      translations,
      locale,
      ns,
    }),
    [locale, ns]
  );

  const i18n = useMemo(() => {
    const instance = createInstance();
    void instance.use(initReactI18next).init({
      lng: locale,
      fallbackLng: "en",
      resources: { [locale]: { [ns]: translations } },
      interpolation: { escapeValue: false },
      react: { useSuspense: false },
    });
    return instance;
  }, [locale, ns, translations]);

  return (
    <CustomI18nContext.Provider value={value}>
      <I18nextProvider i18n={i18n}>{children}</I18nextProvider>
    </CustomI18nContext.Provider>
  );
}
