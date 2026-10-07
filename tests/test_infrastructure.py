import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


def load_template(name):
    return json.loads((ROOT / "build" / name).read_text())


def resources(template, resource_type):
    items = template["resources"]
    if isinstance(items, dict):
        items = items.values()
    return [item for item in items if item["type"].lower() == resource_type.lower()]


class InfrastructureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.template = load_template("main.json")
        cls.parameters = load_template("main.parameters.json")["parameters"]
        cls.cluster = resources(cls.template, "Microsoft.ContainerService/managedClusters")[0]

    def test_region_and_vm_size(self):
        for name, value in (
            ("location", "northeurope"),
            ("acrLocation", "swedencentral"),
            ("nodeVmSize", "Standard_D4s_v6"),
        ):
            with self.subTest(parameter=name):
                self.assertEqual(self.template["parameters"][name]["defaultValue"], value)
                self.assertEqual(self.parameters[name]["value"], value)
        self.assertEqual(self.cluster["location"], "[parameters('location')]")
        registry = resources(self.template, "Microsoft.ContainerRegistry/registries")[0]
        self.assertEqual(registry["location"], "[parameters('acrLocation')]")

    def test_exact_node_pool_configuration(self):
        pools = self.cluster["properties"]["agentPoolProfiles"]
        self.assertEqual(
            [(pool["name"], pool["mode"], pool["count"]) for pool in pools],
            [("system", "System", 2), ("user", "User", 1)],
        )
        for pool in pools:
            with self.subTest(pool=pool["name"]):
                self.assertEqual(pool["vmSize"], "[parameters('nodeVmSize')]")
                self.assertEqual(pool["osType"], "Linux")
                self.assertFalse(pool["enableAutoScaling"])

    def test_cilium_public_api_and_workload_identity(self):
        properties = self.cluster["properties"]
        network = properties["networkProfile"]
        self.assertEqual(network["networkPlugin"], "azure")
        self.assertEqual(network["networkPluginMode"], "overlay")
        self.assertEqual(network["networkDataplane"], "cilium")
        self.assertFalse(properties["apiServerAccessProfile"]["enablePrivateCluster"])
        self.assertTrue(properties["enableRBAC"])
        self.assertTrue(properties["oidcIssuerProfile"]["enabled"])
        self.assertTrue(properties["securityProfile"]["workloadIdentity"]["enabled"])

    def test_registry_pull_access(self):
        registry = resources(self.template, "Microsoft.ContainerRegistry/registries")[0]
        self.assertEqual(registry["sku"]["name"], "Basic")
        self.assertFalse(registry["properties"]["adminUserEnabled"])
        assignments = resources(self.template, "Microsoft.Authorization/roleAssignments")
        self.assertEqual(len(assignments), 1)
        assignment = assignments[0]
        self.assertIn("Microsoft.ContainerRegistry/registries", assignment["scope"])
        self.assertIn("kubeletidentity.objectId", assignment["properties"]["principalId"])
        self.assertEqual(assignment["properties"]["principalType"], "ServicePrincipal")
        self.assertIn(
            "7f951dda-4ed3-4680-a7ca-43fe172d538d",
            self.template["variables"]["acrPullRoleDefinitionId"],
        )

    def test_flux_installed_without_repository_sync(self):
        extensions = resources(self.template, "Microsoft.KubernetesConfiguration/extensions")
        self.assertEqual(len(extensions), 1)
        self.assertIn("Microsoft.ContainerService/managedClusters", extensions[0]["scope"])
        properties = extensions[0]["properties"]
        self.assertEqual(properties["extensionType"], "microsoft.flux")
        self.assertEqual(properties["scope"]["cluster"]["releaseNamespace"], "flux-system")
        self.assertTrue(properties["autoUpgradeMinorVersion"])
        self.assertEqual(resources(self.template, "Microsoft.KubernetesConfiguration/fluxConfigurations"), [])

    def test_deployment_identity_trusts_production_environment(self):
        template = load_template("github-oidc.json")
        self.assertEqual(
            template["parameters"]["githubSubjectPrefix"]["defaultValue"],
            "repo:pelithne@45140408/hsb-azure-day@1408351006",
        )
        self.assertEqual(template["parameters"]["githubEnvironment"]["defaultValue"], "production")
        credentials = resources(
            template,
            "Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials",
        )
        self.assertEqual(len(credentials), 1)
        properties = credentials[0]["properties"]
        self.assertEqual(properties["issuer"], "https://token.actions.githubusercontent.com")
        self.assertEqual(
            properties["subject"],
            "[format('{0}:environment:{1}', parameters('githubSubjectPrefix'), parameters('githubEnvironment'))]",
        )
        self.assertEqual(properties["audiences"], ["api://AzureADTokenExchange"])
        assignments = resources(template, "Microsoft.Authorization/roleAssignments")
        self.assertEqual(len(assignments), 2)
        for assignment in assignments:
            self.assertNotIn("scope", assignment)
            self.assertEqual(assignment["properties"]["principalType"], "ServicePrincipal")


if __name__ == "__main__":
    unittest.main()
