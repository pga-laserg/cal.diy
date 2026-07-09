import type { Credential, PlatformOAuthClient, Team, User } from "@calcom/prisma/client";
import { INestApplication } from "@nestjs/common";
import { NestExpressApplication } from "@nestjs/platform-express";
import { Test } from "@nestjs/testing";
import { OAuth2Client } from "googleapis-common";
import request from "supertest";
import { CredentialsRepositoryFixture } from "test/fixtures/repository/credentials.repository.fixture";
import { OAuthClientRepositoryFixture } from "test/fixtures/repository/oauth-client.repository.fixture";
import { TeamRepositoryFixture } from "test/fixtures/repository/team.repository.fixture";
import { TokensRepositoryFixture } from "test/fixtures/repository/tokens.repository.fixture";
import { UserRepositoryFixture } from "test/fixtures/repository/users.repository.fixture";
import { CalendarsServiceMock } from "test/mocks/calendars-service-mock";
import { randomString } from "test/utils/randomString";
import { AppModule } from "@/app.module";
import { bootstrap } from "@/bootstrap";
import { HttpExceptionFilter } from "@/filters/http-exception.filter";
import { PrismaExceptionFilter } from "@/filters/prisma-exception.filter";
import { GCalService } from "@/modules/apps/services/gcal.service";
import { PermissionsGuard } from "@/modules/auth/guards/permissions/permissions.guard";
import { TokensModule } from "@/modules/tokens/tokens.module";
import { UsersModule } from "@/modules/users/users.module";
import { CalendarsService } from "@/platform/calendars/services/calendars.service";

const CLIENT_REDIRECT_URI = "http://localhost:5555";

let describePlatformGcal: typeof describe = describe;
// biome-ignore lint/style/noProcessEnv: Need to check env availability before test setup
if (!process.env.GOOGLE_API_CREDENTIALS) {
  describePlatformGcal = describe.skip;
}

describePlatformGcal("Platform Gcal Endpoints", () => {
  let app: INestApplication;

  let oAuthClient: PlatformOAuthClient;
  let organization: Team;
  let userRepositoryFixture: UserRepositoryFixture;
  let oauthClientRepositoryFixture: OAuthClientRepositoryFixture;
  let teamRepositoryFixture: TeamRepositoryFixture;
  let tokensRepositoryFixture: TokensRepositoryFixture;
  let credentialsRepositoryFixture: CredentialsRepositoryFixture;
  let user: User;
  let gcalCredentials: Credential;
  let accessTokenSecret: string;
  let refreshTokenSecret: string;

  beforeAll(async () => {
    const moduleRef = await Test.createTestingModule({
      providers: [PrismaExceptionFilter, HttpExceptionFilter],
      imports: [AppModule, UsersModule, TokensModule],
    })
      .overrideGuard(PermissionsGuard)
      .useValue({
        canActivate: () => true,
      })
      .compile();

    app = moduleRef.createNestApplication();
    bootstrap(app as NestExpressApplication);

    oauthClientRepositoryFixture = new OAuthClientRepositoryFixture(moduleRef);
    userRepositoryFixture = new UserRepositoryFixture(moduleRef);
    teamRepositoryFixture = new TeamRepositoryFixture(moduleRef);
    tokensRepositoryFixture = new TokensRepositoryFixture(moduleRef);
    credentialsRepositoryFixture = new CredentialsRepositoryFixture(moduleRef);
    organization = await teamRepositoryFixture.create({ name: `gcal-organization-${randomString()}` });
    oAuthClient = await createOAuthClient(organization.id);
    user = await userRepositoryFixture.createOAuthManagedUser(
      `gcal-connect-${randomString()}@api.com`,
      oAuthClient.id
    );
    const tokens = await tokensRepositoryFixture.createTokens(user.id, oAuthClient.id);
    accessTokenSecret = tokens.accessToken;
    refreshTokenSecret = tokens.refreshToken;
    await app.init();
    jest.spyOn(GCalService.prototype, "getOAuthClient").mockImplementation(async (redirectUri: string) => {
      return new OAuth2Client("test-client-id", "test-client-secret", redirectUri);
    });
    jest
      .spyOn(CalendarsService.prototype, "getCalendars")
      .mockImplementation(CalendarsServiceMock.prototype.getCalendars);
  });

  async function createOAuthClient(organizationId: number): Promise<PlatformOAuthClient> {
    const data = {
      logo: "logo-url",
      name: "name",
      redirectUris: [CLIENT_REDIRECT_URI],
      permissions: 32,
    };
    const secret = "secret";

    const client = await oauthClientRepositoryFixture.create(organizationId, data, secret);
    return client;
  }

  it("should be defined", () => {
    expect(oauthClientRepositoryFixture).toBeDefined();
    expect(userRepositoryFixture).toBeDefined();
    expect(oAuthClient).toBeDefined();
    expect(accessTokenSecret).toBeDefined();
    expect(refreshTokenSecret).toBeDefined();
    expect(user).toBeDefined();
  });

  it(`/GET/gcal/oauth/auth-url: it should respond 401 with invalid access token`, async () => {
    await request(app.getHttpServer())
      .get(`/v2/gcal/oauth/auth-url`)
      .set("Authorization", `Bearer invalid_access_token`)
      .expect(401);
  });

  it(`/GET/gcal/oauth/auth-url: it should auth-url to google OAuth with valid access token `, async () => {
    const response = await request(app.getHttpServer())
      .get(`/v2/gcal/oauth/auth-url`)
      .set("Authorization", `Bearer ${accessTokenSecret}`)
      .set("Origin", CLIENT_REDIRECT_URI)
      .expect(200);
    const data = response.body.data;
    expect(data.authUrl).toBeDefined();
  });

  it(`/GET/gcal/oauth/save: without OAuth code`, async () => {
    await request(app.getHttpServer())
      .get(
        `/v2/gcal/oauth/save?state=accessToken=${accessTokenSecret}&origin%3D${CLIENT_REDIRECT_URI}&scope=https://www.googleapis.com/auth/calendar.readonly%20https://www.googleapis.com/auth/calendar.events`
      )
      .expect(301);
  });

  it(`/GET/gcal/oauth/save: without access token`, async () => {
    await request(app.getHttpServer())
      .get(
        `/v2/gcal/oauth/save?state=origin%3D${CLIENT_REDIRECT_URI}&code=4/0AfJohXmBuT7QVrEPlAJLBu4ZcSnyj5jtDoJqSW_riPUhPXQ70RPGkOEbVO3xs-OzQwpPQw&scope=https://www.googleapis.com/auth/calendar.readonly%20https://www.googleapis.com/auth/calendar.events`
      )
      .expect(301);
  });

  it(`/GET/gcal/oauth/save: without origin`, async () => {
    await request(app.getHttpServer())
      .get(
        `/v2/gcal/oauth/save?state=accessToken=${accessTokenSecret}&code=4/0AfJohXmBuT7QVrEPlAJLBu4ZcSnyj5jtDoJqSW_riPUhPXQ70RPGkOEbVO3xs-OzQwpPQw&scope=https://www.googleapis.com/auth/calendar.readonly%20https://www.googleapis.com/auth/calendar.events`
      )
      .expect(301);
  });

  it(`/GET/gcal/check with access token but without origin`, async () => {
    await request(app.getHttpServer())
      .get(`/v2/gcal/check`)
      .set("Authorization", `Bearer ${accessTokenSecret}`)
      .expect(400);
  });

  it(`/GET/gcal/check without access token`, async () => {
    await request(app.getHttpServer()).get(`/v2/gcal/check`).expect(401);
  });

  it(`/GET/gcal/check with access token and origin but no credentials`, async () => {
    await request(app.getHttpServer())
      .get(`/v2/gcal/check`)
      .set("Authorization", `Bearer ${accessTokenSecret}`)
      .set("Origin", CLIENT_REDIRECT_URI)
      .expect(400);
  });

  it(`/GET/gcal/check with access token and origin and gcal credentials`, async () => {
    gcalCredentials = await credentialsRepositoryFixture.create(
      "google_calendar",
      {},
      user.id,
      "google-calendar"
    );
    await request(app.getHttpServer())
      .get(`/v2/gcal/check`)
      .set("Authorization", `Bearer ${accessTokenSecret}`)
      .set("Origin", CLIENT_REDIRECT_URI)
      .expect(200);
  });

  afterAll(async () => {
    const cleanupTasks: Promise<unknown>[] = [];
    if (oAuthClient) {
      cleanupTasks.push(oauthClientRepositoryFixture.delete(oAuthClient.id));
    }
    if (organization) {
      cleanupTasks.push(teamRepositoryFixture.delete(organization.id));
    }
    if (gcalCredentials) {
      cleanupTasks.push(credentialsRepositoryFixture.delete(gcalCredentials.id));
    }
    if (user) {
      cleanupTasks.push(userRepositoryFixture.deleteByEmail(user.email));
    }
    await Promise.allSettled(cleanupTasks);
    await app?.close();
    jest.restoreAllMocks();
  });
});
