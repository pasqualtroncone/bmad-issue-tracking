"""Lab fixture — the only 'product' code in the consumer project."""


def login(username: str, password: str) -> bool:
    return username == "alice" and password == "secret"
