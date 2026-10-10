"""proxy-node-compat —— 跨代理内核的节点兼容性判断层（只判断, 不生成配置）。"""
from .engine import Target, EvaluationResult, evaluate, LEVELS
from .model import Field, Feature, NodeProfile, Presence, Provenance, valid_feature_id
from .registry import Registry, default_registry_path, parse_version
from .uri import generate_uri, parse_uri

__all__ = ["Target", "EvaluationResult", "evaluate", "LEVELS", "Field", "Feature",
           "NodeProfile", "Presence", "Provenance", "valid_feature_id", "Registry",
           "default_registry_path", "parse_version", "parse_uri", "generate_uri",
           "check_node", "__version__"]
__version__ = "0.1.0"


def check_node(uri_or_profile, target, registry=None):
    """最简入口: URI 字符串或 NodeProfile → EvaluationResult。"""
    profile = (parse_uri(uri_or_profile) if isinstance(uri_or_profile, str)
               else uri_or_profile)
    reg = registry or Registry.load(default_registry_path())
    return evaluate(profile, target, reg)
