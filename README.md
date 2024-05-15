# EM cache

This service caches the client queries using redis.

two http routes are present using the post method:

- `/query`: for getting the results of a previously stored query
- `/cache`: for caching new results 
