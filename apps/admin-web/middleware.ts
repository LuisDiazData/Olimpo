import { NextRequest, NextResponse } from "next/server"

export function middleware(request: NextRequest) {
  const session = request.cookies.get("admin_session")
  const isLogin = request.nextUrl.pathname.startsWith("/login")

  if (!session && !isLogin) {
    return NextResponse.redirect(new URL("/login", request.url))
  }
  if (session && isLogin) {
    return NextResponse.redirect(new URL("/", request.url))
  }
  return NextResponse.next()
}

export const config = {
  matcher: [
    "/((?!_next/static|_next/image|favicon\\.ico|login$|api/auth/.*).*)",
  ],
}
