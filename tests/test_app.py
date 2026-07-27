import unittest

from fastapi.testclient import TestClient

from src.app import app


class AppTestCase(unittest.TestCase):
    def setUp(self):
        self.client = TestClient(app)

    def test_home_page_shows_deployment_flow(self):
        response = self.client.get("/")

        self.assertEqual(response.status_code, 200)
        self.assertIn("현업 아이디어를 안전하게 서비스로", response.text)
        self.assertNotIn("소스 생성은 GitHub Copilot", response.text)
        self.assertIn("<span>Actions</span>", response.text)

    def test_health_check_returns_ok(self):
        response = self.client.get("/healthz")

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["status"], "ok")
        self.assertIn("release", response.json())


if __name__ == "__main__":
    unittest.main()
