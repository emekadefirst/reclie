"""
This file runs a benchmark test across request, httpx, aiohttp, http.client and reclie

target host : https://dummyjson.com

1. GET /products
2.POST /auth/login { username: 'emilys', password: 'emilyspass'}

3. GET /auth/me parsing the accessToken from 2. response
4. GET /products/search?q=phone'

"""


import http.client
import aiohttp
import requests
import httpx
import reclie