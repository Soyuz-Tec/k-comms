import copy
import json
import unittest
from jsonschema import Draft202012Validator, FormatChecker
from validate_contracts import CONTRACTS, load_yaml, validate_federation_contract

class FederationContractTests(unittest.TestCase):
    def setUp(self):
        self.document = load_yaml(CONTRACTS / 'openapi/openapi.yaml')
        self.payload = json.loads((CONTRACTS / 'json-schema/federation.v1.json').read_text())

    def test_current_contract_and_exact_standalone_family(self):
        validate_federation_contract(self.document, self.payload)

    def test_private_mapping_or_credentials_cannot_become_wire_fields(self):
        for field in ('access_token', 'provider_room_box', 'session_id', 'provider_receipt_box', 'provider_bridge_user', 'bridge_user', 'effect_mode'):
            changed = copy.deepcopy(self.document)
            changed['components']['schemas']['FederationRoom']['properties'][field] = {'type': 'string'}
            with self.assertRaisesRegex(ValueError, 'exact owner wire fields'):
                validate_federation_contract(changed)

    def test_unproven_remote_receipts_cannot_claim_deletion_or_geography(self):
        for schema, field in [('FederationTimeline', 'remote_deletion_confirmed'), ('FederationMetadataExport', 'remote_deletion_confirmed'), ('FederationTrust', 'residency_verified')]:
            changed = copy.deepcopy(self.document)
            changed['components']['schemas'][schema]['properties'][field] = {'type': 'boolean'}
            with self.assertRaisesRegex(ValueError, 'cannot attest'):
                validate_federation_contract(changed)

    def test_disclosure_authentication_and_private_cache_receipts_are_required(self):
        changed = copy.deepcopy(self.document)
        changed['paths']['/api/v1/admin/federation/trusts']['put']['security'] = []
        with self.assertRaisesRegex(ValueError, 'current authenticated'):
            validate_federation_contract(changed)
        changed = copy.deepcopy(self.document)
        changed['components']['schemas']['FederationCreateRequest']['properties']['plaintext_disclosure_accepted'] = {'type': 'boolean'}
        with self.assertRaisesRegex(ValueError, 'explicit plaintext'):
            validate_federation_contract(changed)

    def test_canonical_domains_reject_malformed_or_private_destinations(self):
        validator = Draft202012Validator(self.payload['$defs']['FederationTrustRequest'], format_checker=FormatChecker())
        for domain in ['REMOTE.example.org', '127.0.0.1', 'remote.example.org\n', 'x.local', 'a..example.org', 'https://remote.example.org', 'remote.example.org:8448']:
            self.assertFalse(validator.is_valid({'domain': domain, 'residency': 'Synthetic region', 'cross_border_reason': 'Reviewed synthetic processing', 'enabled': True}), domain)

    def test_acceptance_requires_disclosure_and_cannot_replace_send_idempotency(self):
        consent = Draft202012Validator(self.payload['$defs']['FederationConsentRequest'])
        self.assertTrue(consent.is_valid({'version': 1, 'accept': False}))
        self.assertFalse(consent.is_valid({'version': 1, 'accept': True}))
        self.assertTrue(consent.is_valid({'version': 1, 'accept': True, 'plaintext_disclosure_accepted': True}))
        changed = copy.deepcopy(self.payload)
        changed['$defs']['FederationSendRequest']['required'].remove('idempotency_key')
        with self.assertRaisesRegex(ValueError, 'Standalone Federation mirror'):
            validate_federation_contract(self.document, changed)

if __name__ == '__main__':
    unittest.main()
