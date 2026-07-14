import type { AppMeta } from "@calcom/types/App";

export const metadata = {
  name: "Daily Video",
  description:
    "Daily Video is AgendaCon's in-house web-based video conferencing platform powered by Daily.co, which is minimalistic and lightweight, but has most of the features you need.",
  installed: !!process.env.DAILY_API_KEY,
  type: "daily_video",
  variant: "conferencing",
  url: "https://daily.co",
  categories: ["conferencing"],
  logo: "icon.svg",
  publisher: "AgendaCon",
  category: "conferencing",
  slug: "daily-video",
  title: "Daily Video",
  isGlobal: true,
  email: "help@cal.com",
  appData: {
    location: {
      linkType: "dynamic",
      type: "integrations:daily",
      label: "Daily Video",
    },
  },
  key: { apikey: process.env.DAILY_API_KEY },
  dirName: "dailyvideo",
  isOAuth: false,
} as AppMeta;

export default metadata;
