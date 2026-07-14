"use client";

import { useLocale } from "@calcom/lib/hooks/useLocale";
import { Button } from "@calcom/ui/components/button";
import { DialogContent, DialogFooter } from "@calcom/ui/components/dialog";
import { SettingsToggle } from "@calcom/ui/components/form";
import { SkeletonButton, SkeletonContainer, SkeletonText } from "@calcom/ui/components/skeleton";
import { showToast } from "@calcom/ui/components/toast";
import { Dialog } from "@calcom/features/components/controlled-dialog";
import { getSupabaseBrowserClient } from "@lib/auth/supabaseNextAuthReact";
import QRCode from "react-qr-code";
import { useEffect, useState } from "react";

type Enrollment = {
  factorId: string;
  secret: string;
  uri: string;
};

const SkeletonLoader = () => (
  <SkeletonContainer>
    <div className="mb-8 mt-6 stack-y-6">
      <div className="flex items-center">
        <SkeletonButton className="mr-6 h-8 w-20 rounded-md p-5" />
        <SkeletonText className="h-8 w-full" />
      </div>
    </div>
  </SkeletonContainer>
);

const syncDashboardMfaStatus = async () => {
  const response = await fetch("/api/auth/supabase/mfa/sync", { method: "POST" });
  return response.ok;
};

const TwoFactorAuthView = () => {
  const { t } = useLocale();
  const [enabled, setEnabled] = useState(false);
  const [isLoading, setIsLoading] = useState(true);
  const [loadFailed, setLoadFailed] = useState(false);
  const [isWorking, setIsWorking] = useState(false);
  const [enrollment, setEnrollment] = useState<Enrollment | null>(null);
  const [disableFactorId, setDisableFactorId] = useState<string | null>(null);
  const [code, setCode] = useState("");

  const loadFactors = async () => {
    setIsLoading(true);
    setLoadFailed(false);
    const supabase = getSupabaseBrowserClient();
    if (!supabase) {
      setLoadFailed(true);
      setIsLoading(false);
      return;
    }

    const { data, error } = await supabase.auth.mfa.listFactors();
    if (error) {
      showToast(t("something_went_wrong"), "error");
      setLoadFailed(true);
      setIsLoading(false);
      return;
    }

    setEnabled(data.totp.some((factor) => factor.status === "verified"));
    setIsLoading(false);
  };

  useEffect(() => {
    void loadFactors();
  }, []); // The Supabase client is a module singleton.

  const startEnrollment = async () => {
    const supabase = getSupabaseBrowserClient();
    if (!supabase) return;

    setIsWorking(true);
    const { data, error } = await supabase.auth.mfa.enroll({
      factorType: "totp",
      friendlyName: "Cal.diy Authenticator",
    });
    setIsWorking(false);

    if (error || !data) {
      showToast(t("something_went_wrong"), "error");
      return;
    }

    setCode("");
    setEnrollment({ factorId: data.id, secret: data.totp.secret, uri: data.totp.uri });
  };

  const closeEnrollment = async () => {
    const supabase = getSupabaseBrowserClient();
    if (supabase && enrollment) {
      await supabase.auth.mfa.unenroll({ factorId: enrollment.factorId });
    }
    setEnrollment(null);
    setCode("");
  };

  const verifyEnrollment = async () => {
    const supabase = getSupabaseBrowserClient();
    if (!supabase || !enrollment || code.trim().length !== 6) return;

    setIsWorking(true);
    const { data: challenge, error: challengeError } = await supabase.auth.mfa.challenge({
      factorId: enrollment.factorId,
    });
    const { error: verifyError } =
      challengeError || !challenge
        ? { error: challengeError ?? new Error("MFA challenge failed") }
        : await supabase.auth.mfa.verify({
            factorId: enrollment.factorId,
            challengeId: challenge.id,
            code: code.trim(),
          });
    setIsWorking(false);

    if (verifyError) {
      showToast(t("incorrect_2fa"), "error");
      return;
    }

    await syncDashboardMfaStatus();
    setEnabled(true);
    setEnrollment(null);
    setCode("");
    showToast(t("enable_2fa"), "success");
  };

  const disableTwoFactor = async () => {
    const supabase = getSupabaseBrowserClient();
    if (!supabase || !disableFactorId || code.trim().length !== 6) return;

    setIsWorking(true);
    const { data: challenge, error: challengeError } = await supabase.auth.mfa.challenge({
      factorId: disableFactorId,
    });
    const { error: verifyError } =
      challengeError || !challenge
        ? { error: challengeError ?? new Error("MFA challenge failed") }
        : await supabase.auth.mfa.verify({
            factorId: disableFactorId,
            challengeId: challenge.id,
            code: code.trim(),
          });

    if (!verifyError) {
      const { error: unenrollError } = await supabase.auth.mfa.unenroll({ factorId: disableFactorId });
      if (unenrollError) {
        setIsWorking(false);
        showToast(t("something_went_wrong"), "error");
        return;
      }
    }
    setIsWorking(false);

    if (verifyError) {
      showToast(t("incorrect_2fa"), "error");
      return;
    }

    await syncDashboardMfaStatus();
    setEnabled(false);
    setDisableFactorId(null);
    setCode("");
    showToast(t("disable_2fa"), "success");
  };

  const requestDisable = async () => {
    const supabase = getSupabaseBrowserClient();
    if (!supabase) return;

    const { data } = await supabase.auth.mfa.listFactors();
    const factor = data?.totp.find((candidate) => candidate.status === "verified");
    if (!factor) {
      showToast(t("something_went_wrong"), "error");
      return;
    }
    setCode("");
    setDisableFactorId(factor.id);
  };

  if (isLoading) return <SkeletonLoader />;

  if (loadFailed) {
    return (
      <div className="border-subtle rounded-b-lg border border-t-0 px-6 py-5">
        <Button color="secondary" onClick={() => void loadFactors()}>
          {t("retry")}
        </Button>
      </div>
    );
  }

  return (
    <>
      <SettingsToggle
        toggleSwitchAtTheEnd
        data-testid="two-factor-switch"
        title={t("two_factor_auth")}
        description={t("add_an_extra_layer_of_security")}
        checked={enabled}
        onCheckedChange={() => (enabled ? void requestDisable() : void startEnrollment())}
        disabled={isWorking}
        switchContainerClassName="rounded-t-none border-t-0"
      />

      <Dialog open={Boolean(enrollment)} onOpenChange={() => void closeEnrollment()}>
        <DialogContent title={t("enable_2fa")} description={t("2fa_scan_image_or_use_code")} type="creation">
          {enrollment && (
            <div className="space-y-5">
              <div className="flex justify-center rounded-lg bg-white p-4">
                <QRCode size={196} value={enrollment.uri} />
              </div>
              <p className="text-center font-mono text-xs text-subtle">{enrollment.secret}</p>
              <label className="block text-sm font-medium text-default" htmlFor="mfa-enrollment-code">
                {t("code")}
              </label>
              <input
                id="mfa-enrollment-code"
                inputMode="numeric"
                autoComplete="one-time-code"
                value={code}
                onChange={(event) => setCode(event.target.value.replace(/\D/g, "").slice(0, 6))}
                className="border-default h-10 w-full rounded-md border px-3"
              />
            </div>
          )}
          <DialogFooter showDivider>
            <Button color="secondary" onClick={() => void closeEnrollment()}>
              {t("cancel")}
            </Button>
            <Button
              loading={isWorking}
              disabled={code.length !== 6 || isWorking}
              onClick={() => void verifyEnrollment()}>
              {t("enable")}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog
        open={Boolean(disableFactorId)}
        onOpenChange={() => {
          setDisableFactorId(null);
          setCode("");
        }}>
        <DialogContent title={t("disable_2fa")} description={t("disable_2fa_recommendation")} type="creation">
          <label className="block text-sm font-medium text-default" htmlFor="mfa-disable-code">
            {t("code")}
          </label>
          <input
            id="mfa-disable-code"
            inputMode="numeric"
            autoComplete="one-time-code"
            value={code}
            onChange={(event) => setCode(event.target.value.replace(/\D/g, "").slice(0, 6))}
            className="border-default mt-2 h-10 w-full rounded-md border px-3"
          />
          <DialogFooter showDivider>
            <Button
              color="secondary"
              onClick={() => {
                setDisableFactorId(null);
                setCode("");
              }}>
              {t("cancel")}
            </Button>
            <Button
              color="destructive"
              loading={isWorking}
              disabled={code.length !== 6 || isWorking}
              onClick={() => void disableTwoFactor()}>
              {t("disable")}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
};

export default TwoFactorAuthView;
