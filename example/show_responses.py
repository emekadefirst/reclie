import asyncio
import json

import reclie


def show(label, resp, body):
    print("\n" + "=" * 70)
    print(label, "->", resp.status_code, "(ok:", str(resp.ok) + ")")
    print("-" * 70)
    print("headers:")
    for k in resp.headers:
        print(f"  {k}: {resp.headers[k]}")
    print("-" * 70)
    print("body:")
    print(json.dumps(body, indent=2)[:1500])


async def main() -> None:
    client = reclie.Client("dummyjson.com")

    r = await client.get("/products/1")
    show("GET /products/1", r, await r.json())

    r = await client.get("/products", params={"limit": 2})
    show("GET /products?limit=2", r, await r.json())

    r = await client.post("/auth/login", json={"username": "emilys", "password": "emilyspass"})
    login = await r.json()
    show("POST /auth/login", r, login)

    token = login["accessToken"]
    r = await client.get("/auth/me", headers={"Authorization": f"Bearer {token}"})
    show("GET /auth/me", r, await r.json())


if __name__ == "__main__":
    asyncio.run(main())
