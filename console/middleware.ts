import { NextResponse, type NextRequest } from "next/server";

// Single-user gate. Set CONSOLE_KEY in the environment; open the console once
// with ?key=<CONSOLE_KEY> and a cookie keeps you in. Leave CONSOLE_KEY empty
// for a local-only console with no gate.
export function middleware(req: NextRequest) {
  const key = process.env.CONSOLE_KEY;
  if (!key) return NextResponse.next();
  const url = req.nextUrl;
  const offered = url.searchParams.get("key");
  if (offered === key) {
    const clean = new URL(url.pathname, url);
    const res = NextResponse.redirect(clean);
    res.cookies.set("fleet_key", key, {
      httpOnly: true,
      sameSite: "lax",
      secure: url.protocol === "https:",
      path: "/",
      maxAge: 60 * 60 * 24 * 90,
    });
    return res;
  }
  if (req.cookies.get("fleet_key")?.value === key) return NextResponse.next();
  return new NextResponse("fleet console — open with ?key=<CONSOLE_KEY> once", { status: 401 });
}

export const config = { matcher: ["/((?!_next|favicon.ico).*)"] };
