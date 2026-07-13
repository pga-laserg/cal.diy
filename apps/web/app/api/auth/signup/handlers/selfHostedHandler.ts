import process from "node:process";
import { sendEmailVerification } from "@calcom/features/auth/lib/verifyEmail";
import { SIGNUP_ERROR_CODES } from "@calcom/features/auth/signup/constants";
import { createOrUpdateMemberships } from "@calcom/features/auth/signup/utils/createOrUpdateMemberships";
import { joinAnyChildTeamOnOrgInvite } from "@calcom/features/auth/signup/utils/organization";
import { prefillAvatar } from "@calcom/features/auth/signup/utils/prefillAvatar";
import {
  findTokenByToken,
  throwIfTokenExpired,
  validateAndGetCorrectedUsernameForTeam,
} from "@calcom/features/auth/signup/utils/token";
import { validateAndGetCorrectedUsernameAndEmail } from "@calcom/features/auth/signup/utils/validateUsername";
import { getUserRepository } from "@calcom/features/di/containers/UserRepository";
import { hashPassword } from "@calcom/lib/auth/hashPassword";
import logger from "@calcom/lib/logger";
import { isPrismaError } from "@calcom/lib/server/getServerErrorFromUnknown";
import { isUsernameReservedDueToMigration } from "@calcom/lib/server/username";
import slugify from "@calcom/lib/slugify";
import { prisma } from "@calcom/prisma";
import { CreationSource, IdentityProvider } from "@calcom/prisma/enums";
import { signupSchema } from "@calcom/prisma/zod-utils";
import { createSupabaseBackedCalUser, isSupabaseAuthUserConflict } from "@lib/auth/supabaseUserProvisioning";
import { NextResponse } from "next/server";

export default async function handler(body: Record<string, string>) {
  const { email, password, language, token } = signupSchema.parse(body);

  const userRepository = getUserRepository();

  const username = slugify(body.username);
  const userEmail = email.toLowerCase();

  if (!username) {
    return NextResponse.json({ message: "Invalid username" }, { status: 422 });
  }

  let foundToken: { id: number; teamId: number | null; expires: Date } | null = null;
  let correctedUsername = username;
  if (token) {
    foundToken = await findTokenByToken({ token });
    throwIfTokenExpired(foundToken?.expires);
    correctedUsername = await validateAndGetCorrectedUsernameForTeam({
      username,
      email: userEmail,
      teamId: foundToken?.teamId,
      isSignup: true,
    });

    if (foundToken?.teamId) {
      const existingUser = await userRepository.findByEmailWithInvitedTo({
        email: userEmail,
      });

      if (existingUser && existingUser.invitedTo !== foundToken.teamId) {
        return NextResponse.json({ message: SIGNUP_ERROR_CODES.USER_ALREADY_EXISTS }, { status: 409 });
      }
    }
  } else {
    const userValidation = await validateAndGetCorrectedUsernameAndEmail({
      username,
      email: userEmail,
      isSignup: true,
    });
    if (!userValidation.isValid) {
      logger.error("User validation failed", { userValidation });
      return NextResponse.json({ message: "Username or email is already taken" }, { status: 409 });
    }
    if (!userValidation.username) {
      return NextResponse.json({ message: "Invalid username" }, { status: 422 });
    }
    correctedUsername = userValidation.username;
  }

  const hashedPassword = await hashPassword(password);

  if (foundToken?.teamId) {
    const team = await prisma.team.findUnique({
      where: {
        id: foundToken.teamId,
      },
      include: {
        parent: {
          select: {
            id: true,
            slug: true,
            organizationSettings: true,
          },
        },
        organizationSettings: true,
      },
    });

    if (team) {
      const isInviteForATeamInOrganization = !!team.parent;
      const isCheckingUsernameInGlobalNamespace = !team.isOrganization && !isInviteForATeamInOrganization;

      if (isCheckingUsernameInGlobalNamespace) {
        const isUsernameAvailable = !(await isUsernameReservedDueToMigration(correctedUsername));
        if (!isUsernameAvailable) {
          return NextResponse.json({ message: "A user exists with that username" }, { status: 409 });
        }
      }

      const organizationId = team.isOrganization ? team.id : (team.parent?.id ?? null);

      const existingUserByUsername = await userRepository.findByUsernameAndOrganizationId({
        username: correctedUsername,
        organizationId,
        excludeEmail: userEmail,
      });

      if (existingUserByUsername) {
        return NextResponse.json({ message: SIGNUP_ERROR_CODES.USER_ALREADY_EXISTS }, { status: 409 });
      }

      let user: { id: number };
      try {
        user = await createSupabaseBackedCalUser({
          creationSource: CreationSource.WEBAPP,
          email: userEmail,
          emailVerified: new Date(Date.now()),
          hashedPassword,
          identityProvider: IdentityProvider.CAL,
          organizationId,
          password,
          username: correctedUsername,
        });
      } catch (error) {
        if (isSupabaseAuthUserConflict(error)) {
          return NextResponse.json({ message: SIGNUP_ERROR_CODES.USER_ALREADY_EXISTS }, { status: 409 });
        }

        if (isPrismaError(error) && error.code === "P2002") {
          const target = String(error.meta?.target ?? "");
          if (target.includes("email") || target.includes("username")) {
            return NextResponse.json({ message: SIGNUP_ERROR_CODES.USER_ALREADY_EXISTS }, { status: 409 });
          }
        }
        throw error;
      }

      await createOrUpdateMemberships({
        user,
        team,
      });

      // Accept any child team invites for orgs.
      if (team.parent) {
        await joinAnyChildTeamOnOrgInvite({
          userId: user.id,
          org: team.parent,
        });
      }
    }

    // Cleanup token after use
    await prisma.verificationToken.delete({
      where: {
        id: foundToken.id,
      },
    });
  } else {
    const isUsernameAvailable = !(await isUsernameReservedDueToMigration(correctedUsername));
    if (!isUsernameAvailable) {
      return NextResponse.json({ message: "A user exists with that username" }, { status: 409 });
    }
    try {
      await createSupabaseBackedCalUser({
        creationSource: CreationSource.WEBAPP,
        email: userEmail,
        emailVerified: null,
        hashedPassword,
        identityProvider: IdentityProvider.CAL,
        locked: false,
        organizationId: null,
        password,
        username: correctedUsername,
      });
    } catch (error) {
      // Fallback for race conditions where user was created between our check and create
      if (isSupabaseAuthUserConflict(error)) {
        return NextResponse.json({ message: SIGNUP_ERROR_CODES.USER_ALREADY_EXISTS }, { status: 409 });
      }

      if (isPrismaError(error) && error.code === "P2002") {
        const target = String(error.meta?.target ?? "");
        if (target.includes("email") || target.includes("username")) {
          return NextResponse.json({ message: SIGNUP_ERROR_CODES.USER_ALREADY_EXISTS }, { status: 409 });
        }
      }
      throw error;
    }

    if (process.env.AVATARAPI_USERNAME && process.env.AVATARAPI_PASSWORD) {
      await prefillAvatar({ email: userEmail });
    }

    await sendEmailVerification({
      email: userEmail,
      username: correctedUsername,
      language,
    });
  }

  return NextResponse.json({ message: "Created user" }, { status: 201 });
}
