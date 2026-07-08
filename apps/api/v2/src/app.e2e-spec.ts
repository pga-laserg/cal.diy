import { X_CAL_CLIENT_ID, X_CAL_SECRET_KEY } from "@calcom/platform-constants";
import type { PlatformOAuthClient, RateLimit, Team, User } from "@calcom/prisma/client";
import { INestApplication } from "@nestjs/common";
import { Test, TestingModule } from "@nestjs/testing";
import request from "supertest";
import { ApiKeysRepositoryFixture } from "test/fixtures/repository/api-keys.repository.fixture";
import { MembershipRepositoryFixture } from "test/fixtures/repository/membership.repository.fixture";
import { OAuthClientRepositoryFixture } from "test/fixtures/repository/oauth-client.repository.fixture";
import { OrganizationRepositoryFixture } from "test/fixtures/repository/organization.repository.fixture";
import { ProfileRepositoryFixture } from "test/fixtures/repository/profiles.repository.fixture";
import { RateLimitRepositoryFixture } from "test/fixtures/repository/rate-limit.repository.fixture";
import { UserRepositoryFixture } from "test/fixtures/repository/users.repository.fixture";
import { randomString } from "test/utils/randomString";
import { AppModule } from "@/app.module";
import { SchedulesModule_2024_04_15 } from "@/platform/schedules/schedules_2024_04_15/schedules.module";
import { CustomThrottlerGuard } from "@/lib/throttler-guard";
import { PrismaModule } from "@/modules/prisma/prisma.module";
import { TokensModule } from "@/modules/tokens/tokens.module";
import { UsersModule } from "@/modules/users/users.module";

describe("AppController", () => {
  describe("Rate limiting", () => {
    let app: INestApplication;
    let userRepositoryFixture: UserRepositoryFixture;
    let apiKeysRepositoryFixture: ApiKeysRepositoryFixture;
    let rateLimitRepositoryFixture: RateLimitRepositoryFixture;
    let userEmail: string;
    let user: User;

    let organization: Team;
    let oAuthClient: PlatformOAuthClient;
    let organizationsRepositoryFixture: OrganizationRepositoryFixture;
    let oauthClientRepositoryFixture: OAuthClientRepositoryFixture;
    let profilesRepositoryFixture: ProfileRepositoryFixture;
    let membershipRepositoryFixture: MembershipRepositoryFixture;

    let apiKeyString: string;

    let rateLimit: RateLimit;
    let apiKeyStringWithRateLimit: string;

    let apiKeyStringWithMultipleLimits: string;
    let firstRateLimitWithMultipleLimits: RateLimit;
    let secondRateLimitWithMultipleLimits: RateLimit;

    const mockDefaultLimit = 2;
    const mockDefaultTtl = 10000;
    const mockDefaultBlockDuration = 10000;
    const apiKeyPrefix = process.env.API_KEY_PREFIX ?? "cal_test_";

    beforeEach(async () => {
      const moduleRef: TestingModule = await Test.createTestingModule({
        imports: [AppModule, PrismaModule, UsersModule, TokensModule, SchedulesModule_2024_04_15],
      }).compile();

      jest.spyOn(CustomThrottlerGuard.prototype, "getDefaultLimit").mockReturnValue(mockDefaultLimit);
      jest.spyOn(CustomThrottlerGuard.prototype, "getDefaultTtl").mockReturnValue(mockDefaultTtl);
      jest
        .spyOn(CustomThrottlerGuard.prototype, "getDefaultBlockDuration")
        .mockReturnValue(mockDefaultBlockDuration);

      userRepositoryFixture = new UserRepositoryFixture(moduleRef);
      userEmail = `app-rate-limits-user-${randomString()}@api.com`;
      user = await userRepositoryFixture.create({
        email: userEmail,
        username: userEmail,
      });

      apiKeysRepositoryFixture = new ApiKeysRepositoryFixture(moduleRef);
      const { keyString } = await apiKeysRepositoryFixture.createApiKey(user.id, null);
      apiKeyString = `${apiKeyPrefix}${keyString}`;

      rateLimitRepositoryFixture = new RateLimitRepositoryFixture(moduleRef);
      const { apiKey, keyString: keyStringWithRateLimit } = await apiKeysRepositoryFixture.createApiKey(
        user.id,
        null
      );
      apiKeyStringWithRateLimit = `${apiKeyPrefix}${keyStringWithRateLimit}`;
      rateLimit = await rateLimitRepositoryFixture.createRateLimit("long", apiKey.id, 10000, 2, 10000);

      const { apiKey: apiKeyWithMultipleLimits, keyString: keyStringWithMultipleLimits } =
        await apiKeysRepositoryFixture.createApiKey(user.id, null);
      apiKeyStringWithMultipleLimits = `${apiKeyPrefix}${keyStringWithMultipleLimits}`;
      firstRateLimitWithMultipleLimits = await rateLimitRepositoryFixture.createRateLimit(
        "short",
        apiKeyWithMultipleLimits.id,
        10000,
        2,
        10000
      );
      secondRateLimitWithMultipleLimits = await rateLimitRepositoryFixture.createRateLimit(
        "long",
        apiKeyWithMultipleLimits.id,
        15000,
        3,
        15000
      );

      organizationsRepositoryFixture = new OrganizationRepositoryFixture(moduleRef);
      organization = await organizationsRepositoryFixture.create({
        name: `app-rate-limits-organization-${randomString()}`,
      });
      oauthClientRepositoryFixture = new OAuthClientRepositoryFixture(moduleRef);
      oAuthClient = await createOAuthClient(organization.id);
      profilesRepositoryFixture = new ProfileRepositoryFixture(moduleRef);
      await profilesRepositoryFixture.create({
        uid: `profile-${randomString()}`,
        username: userEmail,
        user: { connect: { id: user.id } },
        organization: { connect: { id: organization.id } },
      });

      membershipRepositoryFixture = new MembershipRepositoryFixture(moduleRef);
      await membershipRepositoryFixture.create({
        user: { connect: { id: user.id } },
        team: { connect: { id: organization.id } },
        role: "OWNER",
        accepted: true,
      });

      app = moduleRef.createNestApplication();
      await app.init();
    });

    async function createOAuthClient(organizationId: number) {
      const data = {
        logo: "logo-url",
        name: "name",
        redirectUris: ["http://localhost:5555"],
        permissions: 1023,
      };
      const secret = "secret";

      const client = await oauthClientRepositoryFixture.create(organizationId, data, secret);
      return client;
    }

    it(
      "api key with default rate limit - should enforce rate limits and reset after block duration",
      async () => {
        const limit = mockDefaultLimit;
        const blockDuration = mockDefaultBlockDuration;

        for (let i = 1; i <= limit; i++) {
          const response = await request(app.getHttpServer())
            .get("/v2/me")
            .set({ Authorization: `Bearer ${apiKeyString}` })
            .expect(200);

          expect(response.headers["x-ratelimit-limit-default"]).toBe(limit.toString());
          expect(response.headers["x-ratelimit-remaining-default"]).toBe((limit - i).toString());
          expect(Number(response.headers["x-ratelimit-reset-default"])).toBeGreaterThan(0);
        }

        const blockedResponse = await request(app.getHttpServer())
          .get("/v2/me")
          .set("Authorization", `Bearer ${apiKeyString}`)
          .expect(429);

        expect(blockedResponse.headers["x-ratelimit-limit-default"]).toBe(limit.toString());
        expect(blockedResponse.headers["x-ratelimit-remaining-default"]).toBe("0");
        expect(Number(blockedResponse.headers["x-ratelimit-reset-default"])).toBeGreaterThan(0);

        await new Promise((resolve) => setTimeout(resolve, blockDuration));

        const afterBlockResponse = await request(app.getHttpServer())
          .get("/v2/me")
          .set("Authorization", `Bearer ${apiKeyString}`)
          .expect(200);

        expect(afterBlockResponse.headers["x-ratelimit-limit-default"]).toBe(limit.toString());
        expect(afterBlockResponse.headers["x-ratelimit-remaining-default"]).toBe((limit - 1).toString());
        expect(Number(afterBlockResponse.headers["x-ratelimit-reset-default"])).toBeGreaterThan(0);
      },
      40 * 1000
    );

    it(
      "api key with custom rate limit - should enforce rate limits and reset after block duration",
      async () => {
        const limit = rateLimit.limit;
        const blockDuration = rateLimit.blockDuration;
        const name = rateLimit.name;

        for (let i = 1; i <= limit; i++) {
          const response = await request(app.getHttpServer())
            .get("/v2/me")
            .set({ Authorization: `Bearer ${apiKeyStringWithRateLimit}` })
            .expect(200);

          expect(response.headers[`x-ratelimit-limit-${name}`]).toBe(limit.toString());
          expect(response.headers[`x-ratelimit-remaining-${name}`]).toBe((limit - i).toString());
          expect(Number(response.headers[`x-ratelimit-reset-${name}`])).toBeGreaterThan(0);
        }

        const blockedResponse = await request(app.getHttpServer())
          .get("/v2/me")
          .set("Authorization", `Bearer ${apiKeyStringWithRateLimit}`)
          .expect(429);

        expect(blockedResponse.headers[`x-ratelimit-limit-${name}`]).toBe(limit.toString());
        expect(blockedResponse.headers[`x-ratelimit-remaining-${name}`]).toBe("0");
        expect(Number(blockedResponse.headers[`x-ratelimit-reset-${name}`])).toBeGreaterThan(0);

        await new Promise((resolve) => setTimeout(resolve, blockDuration));

        const afterBlockResponse = await request(app.getHttpServer())
          .get("/v2/me")
          .set("Authorization", `Bearer ${apiKeyStringWithRateLimit}`)
          .expect(200);

        expect(afterBlockResponse.headers[`x-ratelimit-limit-${name}`]).toBe(limit.toString());
        expect(afterBlockResponse.headers[`x-ratelimit-remaining-${name}`]).toBe((limit - 1).toString());
        expect(Number(afterBlockResponse.headers[`x-ratelimit-reset-${name}`])).toBeGreaterThan(0);
      },
      40 * 1000
    );

    it(
      "api key with multiple rate limits - should enforce both short and long rate limits",
      async () => {
        const shortLimit = firstRateLimitWithMultipleLimits.limit;
        const longLimit = secondRateLimitWithMultipleLimits.limit;
        const shortName = firstRateLimitWithMultipleLimits.name;
        const longName = secondRateLimitWithMultipleLimits.name;
        const shortBlock = firstRateLimitWithMultipleLimits.blockDuration;
        const longBlock = secondRateLimitWithMultipleLimits.blockDuration;

        let requestsMade = 0;
        // note(Lauris): exhaust short limit to have remaining 0 for it
        for (let i = 1; i <= shortLimit; i++) {
          const response = await request(app.getHttpServer())
            .get("/v2/me")
            .set({ Authorization: `Bearer ${apiKeyStringWithMultipleLimits}` })
            .expect(200);

          requestsMade++;

          expect(response.headers[`x-ratelimit-limit-${shortName}`]).toBe(shortLimit.toString());
          expect(response.headers[`x-ratelimit-remaining-${shortName}`]).toBe((shortLimit - i).toString());
          expect(Number(response.headers[`x-ratelimit-reset-${shortName}`])).toBeGreaterThan(0);

          expect(response.headers[`x-ratelimit-limit-${longName}`]).toBe(longLimit.toString());
          expect(response.headers[`x-ratelimit-remaining-${longName}`]).toBe((longLimit - i).toString());
          expect(Number(response.headers[`x-ratelimit-reset-${longName}`])).toBeGreaterThan(0);
        }

        // note(Lauris): short limit exhausted, now exhaust long limit to have remaining 0 for it
        for (let i = requestsMade; i < longLimit; i++) {
          const responseAfterShortLimit = await request(app.getHttpServer())
            .get("/v2/me")
            .set({ Authorization: `Bearer ${apiKeyStringWithMultipleLimits}` })
            .expect(200);

          requestsMade++;

          expect(responseAfterShortLimit.headers[`x-ratelimit-limit-${shortName}`]).toBe(
            shortLimit.toString()
          );
          expect(responseAfterShortLimit.headers[`x-ratelimit-remaining-${shortName}`]).toBe("0");
          expect(Number(responseAfterShortLimit.headers[`x-ratelimit-reset-${shortName}`])).toBeGreaterThan(
            0
          );

          expect(responseAfterShortLimit.headers[`x-ratelimit-limit-${longName}`]).toBe(longLimit.toString());
          expect(responseAfterShortLimit.headers[`x-ratelimit-remaining-${longName}`]).toBe(
            (longLimit - requestsMade).toString()
          );
          expect(Number(responseAfterShortLimit.headers[`x-ratelimit-reset-${longName}`])).toBeGreaterThan(0);
        }

        // note(Lauris): both have remaining 0 so now exceed both
        const blockedResponseLong = await request(app.getHttpServer())
          .get("/v2/me")
          .set({ Authorization: `Bearer ${apiKeyStringWithMultipleLimits}` })
          .expect(429);

        expect(blockedResponseLong.headers[`x-ratelimit-limit-${shortName}`]).toBe(shortLimit.toString());
        expect(blockedResponseLong.headers[`x-ratelimit-remaining-${shortName}`]).toBe("0");
        expect(Number(blockedResponseLong.headers[`x-ratelimit-reset-${shortName}`])).toBeGreaterThan(0);

        expect(blockedResponseLong.headers[`x-ratelimit-limit-${longName}`]).toBe(longLimit.toString());
        expect(blockedResponseLong.headers[`x-ratelimit-remaining-${longName}`]).toBe("0");
        expect(Number(blockedResponseLong.headers[`x-ratelimit-reset-${longName}`])).toBeGreaterThan(0);

        // note(Lauris): wait for short limit to reset
        await new Promise((resolve) => setTimeout(resolve, shortBlock));
        const responseAfterShortLimitReload = await request(app.getHttpServer())
          .get("/v2/me")
          .set({ Authorization: `Bearer ${apiKeyStringWithMultipleLimits}` })
          .expect(200);
        expect(responseAfterShortLimitReload.headers[`x-ratelimit-limit-${shortName}`]).toBe(
          shortLimit.toString()
        );
        expect(responseAfterShortLimitReload.headers[`x-ratelimit-remaining-${shortName}`]).toBe(
          (shortLimit - 1).toString()
        );
        expect(
          Number(responseAfterShortLimitReload.headers[`x-ratelimit-reset-${shortName}`])
        ).toBeGreaterThan(0);
        expect(responseAfterShortLimitReload.headers[`x-ratelimit-limit-${longName}`]).toBe(
          longLimit.toString()
        );
        expect(responseAfterShortLimitReload.headers[`x-ratelimit-remaining-${longName}`]).toBe(
          (longLimit - requestsMade).toString()
        );
        expect(
          Number(responseAfterShortLimitReload.headers[`x-ratelimit-reset-${longName}`])
        ).toBeGreaterThan(0);

        // note(Lauris): wait for long limit to reset
        await new Promise((resolve) => setTimeout(resolve, longBlock));
        const responseAfterLongLimitReload = await request(app.getHttpServer())
          .get("/v2/me")
          .set({ Authorization: `Bearer ${apiKeyStringWithMultipleLimits}` })
          .expect(200);
        expect(responseAfterLongLimitReload.headers[`x-ratelimit-limit-${shortName}`]).toBe(
          shortLimit.toString()
        );
        expect(responseAfterLongLimitReload.headers[`x-ratelimit-remaining-${shortName}`]).toBe(
          (shortLimit - 1).toString()
        );
        expect(
          Number(responseAfterLongLimitReload.headers[`x-ratelimit-reset-${shortName}`])
        ).toBeGreaterThan(0);
        expect(responseAfterLongLimitReload.headers[`x-ratelimit-limit-${longName}`]).toBe(
          longLimit.toString()
        );
        expect(responseAfterLongLimitReload.headers[`x-ratelimit-remaining-${longName}`]).toBe(
          (longLimit - 1).toString()
        );
        expect(Number(responseAfterLongLimitReload.headers[`x-ratelimit-reset-${longName}`])).toBeGreaterThan(
          0
        );
      },
      60 * 1000
    );

    it(
      "non api key with default rate limit - should enforce rate limits and reset after block duration",
      async () => {
        const limit = mockDefaultLimit;
        const blockDuration = mockDefaultBlockDuration;

        for (let i = 1; i <= limit; i++) {
          const response = await request(app.getHttpServer())
            .get("/v2/me")
            .set(X_CAL_CLIENT_ID, oAuthClient.id)
            .set(X_CAL_SECRET_KEY, oAuthClient.secret)
            .expect(200);

          expect(response.headers["x-ratelimit-limit-default"]).toBe(limit.toString());
          expect(response.headers["x-ratelimit-remaining-default"]).toBe((limit - i).toString());
          expect(Number(response.headers["x-ratelimit-reset-default"])).toBeGreaterThan(0);
        }

        const blockedResponse = await request(app.getHttpServer())
          .get("/v2/me")
          .set(X_CAL_CLIENT_ID, oAuthClient.id)
          .set(X_CAL_SECRET_KEY, oAuthClient.secret)
          .expect(429);

        expect(blockedResponse.headers["x-ratelimit-limit-default"]).toBe(limit.toString());
        expect(blockedResponse.headers["x-ratelimit-remaining-default"]).toBe("0");
        expect(Number(blockedResponse.headers["x-ratelimit-reset-default"])).toBeGreaterThan(0);

        await new Promise((resolve) => setTimeout(resolve, blockDuration));

        const afterBlockResponse = await request(app.getHttpServer())
          .get("/v2/me")
          .set(X_CAL_CLIENT_ID, oAuthClient.id)
          .set(X_CAL_SECRET_KEY, oAuthClient.secret)
          .expect(200);

        expect(afterBlockResponse.headers["x-ratelimit-limit-default"]).toBe(limit.toString());
        expect(afterBlockResponse.headers["x-ratelimit-remaining-default"]).toBe((limit - 1).toString());
        expect(Number(afterBlockResponse.headers["x-ratelimit-reset-default"])).toBeGreaterThan(0);
      },
      40 * 1000
    );

    afterEach(async () => {
      await Promise.allSettled([
        userEmail ? userRepositoryFixture.deleteByEmail(userEmail) : Promise.resolve(),
        organization ? organizationsRepositoryFixture.delete(organization.id) : Promise.resolve(),
      ]);
      await app?.close();
      jest.restoreAllMocks();
    });
  });
});
