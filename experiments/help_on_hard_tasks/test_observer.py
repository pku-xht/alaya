"""Check the observer's narrow, credential-free output contract."""
import unittest
from observe_http import header_metadata

class HeaderTests(unittest.TestCase):
    def test_last_status_units_and_sensitive_fields_excluded(self):
        result = header_metadata('HTTP/1.1 200 Connection established\r\n\r\nHTTP/2 429\r\n'
                                 'Retry-After: 60\r\nretry-after-ms: 1200\r\n'
                                 'Authorization: secret-sentinel\r\nSet-Cookie: private\r\n')
        self.assertEqual(result, {'http_status': 429, 'retry_after': [
            {'value': 60, 'unit': 'seconds'}, {'value': 1200, 'unit': 'milliseconds'}]})

    def test_missing_or_date_retry_not_guessed(self):
        self.assertEqual(header_metadata('Retry-After: Wed, 21 Oct 2026 07:28:00 GMT\r\n'),
                         {'http_status': None, 'retry_after': []})

if __name__ == '__main__':
    unittest.main()
