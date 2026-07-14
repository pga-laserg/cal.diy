import getApps from "@calcom/app-store/utils";
import { eventTypeMetaDataSchemaWithTypedApps } from "@calcom/app-store/zod-utils";
import { BookingEmailAndSmsTaskService } from "@calcom/features/bookings/lib/tasker/BookingEmailAndSmsTaskService";
import { getBookingEmailAndSmsTaskService } from "@calcom/features/bookings/di/tasker/BookingEmailAndSmsTaskService.container";
import { handleConfirmation } from "@calcom/features/bookings/lib/handleConfirmation";
import { handleBookingRequested } from "@calcom/features/bookings/lib/handleBookingRequested";
import { handlePayment } from "@calcom/features/bookings/lib/handlePayment";
import type { Fields } from "@calcom/features/bookings/lib/getBookingFields";
import { getWebhookPayloadForBooking } from "@calcom/features/bookings/lib/getWebhookPayloadForBooking";
import { handleWebhookTrigger } from "@calcom/features/bookings/lib/handleWebhookTrigger";
import EventManager from "@calcom/features/bookings/lib/EventManager";
import type { IEventTypePaymentCredentialType } from "@calcom/features/bookings/lib/handleNewBooking/types";
import { getBooking } from "@calcom/features/bookings/lib/payment/getBooking";
import { BookingRepository } from "@calcom/features/bookings/repositories/BookingRepository";
import { distributedTracing } from "@calcom/lib/tracing/factory";
import logger from "@calcom/lib/logger";
import { safeStringify } from "@calcom/lib/safeStringify";
import type { TraceContext } from "@calcom/lib/tracing";
import prisma, { type PrismaTransaction } from "@calcom/prisma";
import type { Prisma } from "@calcom/prisma/client";

type BookingEffectKind =
  | "calendar_create"
  | "calendar_reschedule"
  | "calendar_cancel"
  | "email_requested"
  | "email_confirmed"
  | "email_rescheduled"
  | "webhook_booking_created"
  | "webhook_booking_requested"
  | "webhook_booking_rescheduled"
  | "payment_initiated"
  | "payment_required";

type BookingEffectRow = {
  id: string;
  booking_uid: string;
  booking_id: string | number;
  effect_kind: BookingEffectKind;
  payload: Record<string, unknown>;
};

type BookingEffectSummary = {
  claimed: number;
  processedBookings: number;
  succeeded: number;
  failed: number;
};

type BookingEffectMap = Record<string, BookingEffectRow[]>;
type EventTypeMetadataWithApps = {
  apps?: Record<
    string,
    {
      enabled?: boolean;
      price?: number;
      paymentOption?: string;
      credentialId?: number;
    }
  >;
} & Record<string, unknown>;

const log = logger.getSubLogger({ prefix: ["[booking-effects]"] });
const BOOKING_EFFECT_BATCH_SIZE = 25;

const CONFIRMATION_EFFECTS: readonly BookingEffectKind[] = [
  "calendar_create",
  "email_confirmed",
  "webhook_booking_created",
];

const REQUEST_EFFECTS: readonly BookingEffectKind[] = ["email_requested", "webhook_booking_requested"];

const RESCHEDULE_EFFECTS: readonly BookingEffectKind[] = [
  "calendar_cancel",
  "email_rescheduled",
  "webhook_booking_rescheduled",
];

const PAYMENT_EFFECTS: readonly BookingEffectKind[] = ["payment_initiated", "payment_required"];

const NON_PAYMENT_EFFECTS: readonly BookingEffectKind[] = [
  ...CONFIRMATION_EFFECTS,
  ...REQUEST_EFFECTS,
  ...RESCHEDULE_EFFECTS,
];

const hasAnyEffect = (effects: readonly BookingEffectKind[], rows: BookingEffectRow[]) =>
  rows.some((row) => effects.includes(row.effect_kind));

const toBookingId = (value: string | number) => Number(value);

const getEffectErrorMessage = (error: unknown) =>
  error instanceof Error ? error.message : safeStringify(error);

const BOOKING_STATUS_ACCEPTED = "ACCEPTED";
const BOOKING_STATUS_CANCELLED = "CANCELLED";
const BOOKING_STATUS_PENDING = "PENDING";

const WEBHOOK_EVENT_BOOKING_CREATED = "BOOKING_CREATED";
const WEBHOOK_EVENT_BOOKING_REQUESTED = "BOOKING_REQUESTED";
const WEBHOOK_EVENT_BOOKING_RESCHEDULED = "BOOKING_RESCHEDULED";
const WEBHOOK_EVENT_BOOKING_PAYMENT_INITIATED = "BOOKING_PAYMENT_INITIATED";

function getPaymentAppCredential(
  booking: Awaited<ReturnType<typeof getBooking>>["booking"],
  eventTypeMetadata: EventTypeMetadataWithApps
): IEventTypePaymentCredentialType | null {
  const paymentAppIds = Object.entries(eventTypeMetadata.apps ?? {})
    .filter(([, data]) => Boolean(data?.enabled) && (data?.price !== undefined || data?.paymentOption))
    .map(([appId]) => appId);

  const installedPaymentApp = getApps(booking.user?.credentials ?? [], true).find((app) => {
    if (!paymentAppIds.includes(app.slug)) return false;
    return app.categories.some((category) => category === "payment");
  });

  if (!installedPaymentApp) {
    return null;
  }

  const appData = eventTypeMetadata.apps?.[installedPaymentApp.slug];
  const credential =
    appData && "credentialId" in appData && appData.credentialId
      ? installedPaymentApp.credentials.find((item) => item.id === appData.credentialId) ??
        installedPaymentApp.credential
      : installedPaymentApp.credential;

  if (!credential || !installedPaymentApp.dirName) {
    return null;
  }

  return {
    key: credential.key,
    appId: installedPaymentApp.slug as IEventTypePaymentCredentialType["appId"],
    app: {
      dirName: installedPaymentApp.dirName,
      categories: installedPaymentApp.categories,
    },
  };
}

export class BookingEffectsTaskProcessor {
  constructor(
    private readonly bookingRepository = new BookingRepository(prisma),
    private readonly bookingEmailAndSmsTaskService: BookingEmailAndSmsTaskService = getBookingEmailAndSmsTaskService()
  ) {}

  async processQueue(limit = BOOKING_EFFECT_BATCH_SIZE): Promise<BookingEffectSummary> {
    const summary: BookingEffectSummary = {
      claimed: 0,
      processedBookings: 0,
      succeeded: 0,
      failed: 0,
    };

    const traceContext = distributedTracing.createTrace("booking_effects_queue");

    await prisma.$transaction(async (tx: PrismaTransaction) => {
      const rows = await tx.$queryRaw<BookingEffectRow[]>`
        select
          id,
          booking_uid,
          booking_id,
          effect_kind,
          payload
        from public.booking_effects
        where status = 'pending'
        order by created_at asc, id asc
        limit ${limit}
        for update skip locked
      `;

      summary.claimed = rows.length;

      if (!rows.length) {
        return;
      }

      const rowsByBooking: BookingEffectMap = {};
      for (const row of rows) {
        const key = String(row.booking_id);
        const current = rowsByBooking[key] ?? [];
        current.push(row);
        rowsByBooking[key] = current;
      }

      for (const bookingId of Object.keys(rowsByBooking)) {
        const bookingRows = rowsByBooking[bookingId] ?? [];
        summary.processedBookings += 1;

        const markDone = async (effectRows: BookingEffectRow[]) => {
          for (const row of effectRows) {
            await tx.$executeRaw`
              update public.booking_effects
              set status = 'done',
                  error = null,
                  processed_at = now(),
                  updated_at = now()
              where id = ${row.id}
            `;
          }
        };

        const markFailed = async (effectRows: BookingEffectRow[], error: unknown) => {
          const message = getEffectErrorMessage(error);
          for (const row of effectRows) {
            await tx.$executeRaw`
              update public.booking_effects
              set status = 'failed',
                  error = ${message},
                  processed_at = now(),
                  updated_at = now()
              where id = ${row.id}
            `;
          }
        };

        try {
          const bookingContext = await getBooking(toBookingId(bookingId));
          if (!bookingContext.booking || !bookingContext.evt || !bookingContext.eventType) {
            throw new Error(`Booking ${bookingId} is missing event context`);
          }

          const booking = bookingContext.booking;
          const evt = bookingContext.evt;
          const eventType = bookingContext.eventType;
          if (!booking.user || !eventType.title) {
            throw new Error(`Booking ${bookingId} is missing its event owner or event type title`);
          }
          const eventTypeMetadata = (eventTypeMetaDataSchemaWithTypedApps.parse(
            eventType.metadata ?? {}
          ) ?? {}) as EventTypeMetadataWithApps;
          const bookingTraceContext = distributedTracing.createSpan(traceContext, "booking_effect", {
            bookingId: booking.id,
            bookingUid: booking.uid,
          });

          const confirmationRows = bookingRows.filter((row) => CONFIRMATION_EFFECTS.includes(row.effect_kind));
          const requestRows = bookingRows.filter((row) => REQUEST_EFFECTS.includes(row.effect_kind));
          const rescheduleRows = bookingRows.filter((row) => RESCHEDULE_EFFECTS.includes(row.effect_kind));
          const paymentRows = bookingRows.filter((row) => PAYMENT_EFFECTS.includes(row.effect_kind));
          const unsupportedRows = bookingRows.filter(
            (row) => !NON_PAYMENT_EFFECTS.includes(row.effect_kind) && !PAYMENT_EFFECTS.includes(row.effect_kind)
          );
          const unsupportedRowIds = new Set(unsupportedRows.map((row) => row.id));

          const hasPaymentEffect = paymentRows.length > 0;
          const hasConfirmationEffect = hasAnyEffect(CONFIRMATION_EFFECTS, bookingRows);
          const hasRequestEffect = hasAnyEffect(REQUEST_EFFECTS, bookingRows);
          const hasRescheduleEffect = hasAnyEffect(RESCHEDULE_EFFECTS, bookingRows);
          const nonPaymentRows = bookingRows.filter(
            (row) => !PAYMENT_EFFECTS.includes(row.effect_kind) && !unsupportedRowIds.has(row.id)
          );

          let nonPaymentSucceeded = false;

          if (booking.status === BOOKING_STATUS_ACCEPTED || hasConfirmationEffect) {
            try {
              await handleConfirmation({
                user: booking.user,
                evt,
                prisma,
                bookingId: booking.id,
                booking,
                paid: booking.paid ?? false,
                traceContext: bookingTraceContext,
              });
              nonPaymentSucceeded = true;
            } catch (error) {
              log.error(`Failed to process confirmation effects for booking ${bookingId}`, {
                error: getEffectErrorMessage(error),
                rows: confirmationRows,
              });
              await markFailed(confirmationRows, error);
              summary.failed += confirmationRows.length;
              continue;
            }
          } else if (booking.status === BOOKING_STATUS_CANCELLED || hasRescheduleEffect) {
            try {
              const bookingWithReferences = await this.bookingRepository.findByIdWithAttendeesPaymentAndReferences(
                booking.id
              );

              if (!bookingWithReferences) {
                throw new Error(`Booking ${booking.id} could not be loaded with references`);
              }

              const eventManager = new EventManager(booking.user, eventTypeMetadata.apps ?? {});
              if (hasAnyEffect(["calendar_cancel"], bookingRows)) {
                await eventManager.cancelEvent(evt, bookingWithReferences.references ?? [], false);
              }

              if (hasAnyEffect(["email_rescheduled"], bookingRows)) {
                await this.bookingEmailAndSmsTaskService.reschedule({
                  bookingId: booking.id,
                });
              }

              if (hasAnyEffect(["webhook_booking_rescheduled"], bookingRows)) {
                const previousBooking = bookingRows
                  .map((row) => row.payload?.["previous_booking"])
                  .find((value) => Boolean(value)) as
                  | { id?: number; uid?: string; startTime?: string; endTime?: string; rescheduledBy?: string }
                  | undefined;

                await handleWebhookTrigger({
                  subscriberOptions: {
                    userId: booking.userId,
                    eventTypeId: booking.eventTypeId ?? undefined,
                    triggerEvent: WEBHOOK_EVENT_BOOKING_RESCHEDULED,
                    teamId: booking.eventType?.teamId ?? null,
                    orgId: undefined,
                  },
                  eventTrigger: WEBHOOK_EVENT_BOOKING_RESCHEDULED,
                  webhookData: {
                    ...getWebhookPayloadForBooking({
                      booking,
                      evt,
                    }),
                    rescheduleId: previousBooking?.id,
                    rescheduleUid: previousBooking?.uid,
                    rescheduleStartTime: previousBooking?.startTime,
                    rescheduleEndTime: previousBooking?.endTime,
                    rescheduledBy: previousBooking?.rescheduledBy,
                  },
                  traceContext: bookingTraceContext,
                });
              }

              nonPaymentSucceeded = true;
            } catch (error) {
              log.error(`Failed to process reschedule effects for booking ${bookingId}`, {
                error: getEffectErrorMessage(error),
                rows: rescheduleRows,
              });
              await markFailed(rescheduleRows, error);
              summary.failed += rescheduleRows.length;
              continue;
            }
          } else if (booking.status === BOOKING_STATUS_PENDING && !hasPaymentEffect && hasRequestEffect) {
            try {
              await handleBookingRequested({
                evt,
                booking,
              });
              nonPaymentSucceeded = true;
            } catch (error) {
              log.error(`Failed to process booking requested effects for booking ${bookingId}`, {
                error: getEffectErrorMessage(error),
                rows: requestRows,
              });
              await markFailed(requestRows, error);
              summary.failed += requestRows.length;
              continue;
            }
          } else if (booking.status === BOOKING_STATUS_PENDING && hasPaymentEffect) {
            nonPaymentSucceeded = true;
          }

          if (nonPaymentSucceeded) {
            await markDone(nonPaymentRows);
            summary.succeeded += nonPaymentRows.length;
          }

          if (paymentRows.length > 0 && booking.status === BOOKING_STATUS_CANCELLED) {
            const cancellationError = new Error("Ignoring payment effects for a cancelled booking");
            await markFailed(paymentRows, cancellationError);
            summary.failed += paymentRows.length;
            continue;
          }

          if (paymentRows.length > 0) {
            try {
              const paymentAppCredentials = getPaymentAppCredential(booking, eventTypeMetadata);

              if (!paymentAppCredentials) {
                throw new Error(`No payment credential found for booking ${booking.id}`);
              }

              const payment = await handlePayment({
                evt,
                selectedEventType: {
                  metadata: eventTypeMetadata as Prisma.JsonValue,
                  title: eventType.title,
                },
                paymentAppCredentials,
                booking,
                bookerName: booking.attendees[0]?.name ?? booking.user?.name ?? "Unknown",
                bookerEmail: booking.attendees[0]?.email ?? booking.user?.email ?? "",
                bookerPhoneNumber: booking.attendees[0]?.phoneNumber ?? booking.smsReminderNumber ?? null,
                bookingFields: booking.eventType?.bookingFields as Fields | undefined,
                locale: booking.attendees[0]?.locale ?? booking.user?.locale ?? "en",
              });

              await handleWebhookTrigger({
                subscriberOptions: {
                  userId: booking.userId,
                  eventTypeId: booking.eventTypeId ?? undefined,
                  triggerEvent: WEBHOOK_EVENT_BOOKING_PAYMENT_INITIATED,
                  teamId: booking.eventType?.teamId ?? null,
                  orgId: undefined,
                },
                eventTrigger: WEBHOOK_EVENT_BOOKING_PAYMENT_INITIATED,
                webhookData: {
                  ...getWebhookPayloadForBooking({
                    booking,
                    evt,
                  }),
                  paymentId: payment?.id,
                  paymentData: payment ?? undefined,
                },
                traceContext: bookingTraceContext,
              });

              await markDone(paymentRows);
              summary.succeeded += paymentRows.length;
            } catch (error) {
              log.error(`Failed to process payment effects for booking ${bookingId}`, {
                error: getEffectErrorMessage(error),
                rows: paymentRows,
              });
              await markFailed(paymentRows, error);
              summary.failed += paymentRows.length;
              continue;
            }
          }

          if (unsupportedRows.length > 0) {
            await markFailed(
              unsupportedRows,
              new Error(
                `Unsupported booking effect kind(s): ${unsupportedRows.map((row) => row.effect_kind).join(", ")}`
              )
            );
            summary.failed += unsupportedRows.length;
          }
        } catch (error) {
          log.error(`Failed to load or process booking effects for booking ${bookingId}`, {
            error: getEffectErrorMessage(error),
            rows: bookingRows,
          });

          await markFailed(bookingRows, error);
          summary.failed += bookingRows.length;
        }
      }
    });

    return summary;
  }
}
