"""HTTPS smoke test against a real external server (dummyjson.com).

Verifies the TLS handshake, certificate verification against the CA bundle,
and framed response reading over an encrypted connection.
"""

import asyncio
import reclie


async def run() -> None:
    client = reclie.Client("dummyjson.com")  # tls=True, port=443 inferred

    resp = await client.get("/products/1")
    print("GET /products/1 ->", resp.status_code, "ok:", resp.ok)
    data = await resp.json()
    print("  title:", data.get("title"))
    assert resp.status_code == 200
    assert "title" in data

    resp2 = await client.post("/auth/login", json={"username": "emilys", "password": "emilyspass"})
    print("POST /auth/login ->", resp2.status_code)
    login = await resp2.json()
    token = login.get("accessToken")
    print("  got token:", bool(token))
    assert resp2.status_code == 200 and token

    # Use the token on a follow-up request.
    resp3 = await client.get("/auth/me", headers={"Authorization": f"Bearer {token}"})
    me = await resp3.json()
    print("GET /auth/me ->", resp3.status_code, "user:", me.get("username"))
    assert resp3.status_code == 200

    resp4 = await client.get("/products/search", params={"q": "phone"})
    search = await resp4.json()
    print("GET /products/search?q=phone ->", resp4.status_code,
          "results:", len(search.get("products", [])))
    assert resp4.status_code == 200

    print("OK")


if __name__ == "__main__":
    asyncio.run(run())
