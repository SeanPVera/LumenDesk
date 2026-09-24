"""Enable opt-in SwiftUI captures in the CI scheme, without changing app launch."""
import os
from pathlib import Path
import xml.etree.ElementTree as ET

path = Path("LumenDesk.xcodeproj/xcshareddata/xcschemes/LumenDesk.xcscheme")
tree = ET.parse(path)
action = tree.getroot().find("TestAction")
assert action is not None, "Shared scheme must have a TestAction"
action.set("shouldUseLaunchSchemeArgsEnv", "NO")
variables = action.find("EnvironmentVariables")
if variables is None:
    variables = ET.SubElement(action, "EnvironmentVariables")
for key, value in {
    "LUMENDESK_RENDER_QA": "1",
    "LUMENDESK_RENDER_DIRECTORY": os.environ["LUMENDESK_RENDER_DIRECTORY"],
}.items():
    ET.SubElement(variables, "EnvironmentVariable", key=key, value=value, isEnabled="YES")
tree.write(path, encoding="UTF-8", xml_declaration=True)
