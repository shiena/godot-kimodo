#include "skeletons.h"

#include <cstring>

namespace skeletons {
namespace {

namespace smplx22 {

const int PARENT[22] = {
	-1, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 9, 9, 12, 13, 14, 16, 17, 18, 19
};

const char *const JOINT_NAME[22] = {
	"pelvis", "left_hip", "right_hip", "spine1",
	"left_knee", "right_knee", "spine2", "left_ankle",
	"right_ankle", "spine3", "left_foot", "right_foot",
	"neck", "left_collar", "right_collar", "head",
	"left_shoulder", "right_shoulder", "left_elbow", "right_elbow",
	"left_wrist", "right_wrist"
};

const char *const HUMANOID_NAME[22] = {
	"Hips", "LeftUpperLeg", "RightUpperLeg", "Spine",
	"LeftLowerLeg", "RightLowerLeg", "Chest", "LeftFoot",
	"RightFoot", "UpperChest", "LeftToes", "RightToes",
	"Neck", "LeftShoulder", "RightShoulder", "Head",
	"LeftUpperArm", "RightUpperArm", "LeftLowerArm", "RightLowerArm",
	"LeftHand", "RightHand"
};

const int SIDE[22] = {
	SIDE_CENTER, SIDE_LEFT, SIDE_RIGHT, SIDE_CENTER, SIDE_LEFT, SIDE_RIGHT,
	SIDE_CENTER, SIDE_LEFT, SIDE_RIGHT, SIDE_CENTER, SIDE_LEFT, SIDE_RIGHT,
	SIDE_CENTER, SIDE_LEFT, SIDE_RIGHT, SIDE_CENTER, SIDE_LEFT, SIDE_RIGHT,
	SIDE_LEFT, SIDE_RIGHT, SIDE_LEFT, SIDE_RIGHT
};

const float REST_OFFSET[22][3] = {
	{ 0.0f, 0.0f, 0.0f },
	{ .052299179f, -.093935639f, -.027606763f },
	{ -.057192899f, -.106548190f, -.022217851f },
	{ -.001495834f, .112929940f, -.024981268f },
	{ .058866613f, -.416441321f, -.006556974f },
	{ -.048074268f, -.397559673f, -.014061437f },
	{ .006900469f, .145636231f, -.006858510f },
	{ -.041737989f, -.437583506f, -.029511765f },
	{ .014489345f, -.446852267f, -.018029511f },
	{ -.010334037f, .056081813f, .021115851f },
	{ .049293540f, -.065279245f, .126259089f },
	{ -.040575184f, -.065286517f, .127075911f },
	{ -.011025756f, .171365142f, -.028827066f },
	{ .047724526f, .087643057f, -.008375450f },
	{ -.046636276f, .086612143f, -.014864366f },
	{ .024654359f, .175390735f, .024463326f },
	{ .126284808f, .057680372f, -.013885141f },
	{ -.109341696f, .053674292f, -.009117880f },
	{ .272907287f, -.069853373f, -.039094493f },
	{ -.292028785f, -.035440356f, -.024564851f },
	{ .276173830f, .021254137f, -.002478220f },
	{ -.271878421f, -.004834589f, -.016445294f }
};

const float LIMB_RADIUS[22] = {
	0.000f, 0.085f, 0.085f, 0.115f, 0.075f, 0.075f,
	0.125f, 0.058f, 0.058f, 0.130f, 0.042f, 0.042f,
	0.055f, 0.065f, 0.065f, 0.050f, 0.058f, 0.058f,
	0.050f, 0.050f, 0.042f, 0.042f
};

} // namespace smplx22

namespace soma30 {

const int PARENT[30] = {
	-1, 0, 1, 2, 3, 4, 5, 6, 6, 6, 3, 10, 11, 12, 13, 13, 3, 16, 17, 18, 19, 19, 0, 22, 23, 24, 0, 26, 27, 28
};

const char *const JOINT_NAME[30] = {
	"Hips", "Spine1", "Spine2", "Chest",
	"Neck1", "Neck2", "Head", "Jaw",
	"LeftEye", "RightEye", "LeftShoulder", "LeftArm",
	"LeftForeArm", "LeftHand", "LeftHandThumbEnd", "LeftHandMiddleEnd",
	"RightShoulder", "RightArm", "RightForeArm", "RightHand",
	"RightHandThumbEnd", "RightHandMiddleEnd", "LeftLeg", "LeftShin",
	"LeftFoot", "LeftToeBase", "RightLeg", "RightShin",
	"RightFoot", "RightToeBase"
};

const char *const HUMANOID_NAME[30] = {
	"Hips", "Spine", "Chest", "UpperChest",
	"Neck", "", "Head", "Jaw",
	"LeftEye", "RightEye", "LeftShoulder", "LeftUpperArm",
	"LeftLowerArm", "LeftHand", "", "",
	"RightShoulder", "RightUpperArm", "RightLowerArm", "RightHand",
	"", "", "LeftUpperLeg", "LeftLowerLeg",
	"LeftFoot", "LeftToes", "RightUpperLeg", "RightLowerLeg",
	"RightFoot", "RightToes"
};

const int SIDE[30] = {
	SIDE_CENTER, SIDE_CENTER, SIDE_CENTER, SIDE_CENTER, SIDE_CENTER, SIDE_CENTER,
	SIDE_CENTER, SIDE_CENTER, SIDE_LEFT, SIDE_RIGHT, SIDE_LEFT, SIDE_LEFT,
	SIDE_LEFT, SIDE_LEFT, SIDE_LEFT, SIDE_LEFT, SIDE_RIGHT, SIDE_RIGHT,
	SIDE_RIGHT, SIDE_RIGHT, SIDE_RIGHT, SIDE_RIGHT, SIDE_LEFT, SIDE_LEFT,
	SIDE_LEFT, SIDE_LEFT, SIDE_RIGHT, SIDE_RIGHT, SIDE_RIGHT, SIDE_RIGHT
};

const float REST_OFFSET[30][3] = {
	{ 0.0f, 0.0f, 0.0f },
	{ -.00013727f, .0500376256f, -.00053726669f },
	{ -1.86574103e-9f, .0712530139f, -.000298248546f },
	{ -5.75188398e-9f, .0755006305f, -.00815970992f },
	{ -.00181676517f, .263112953f, -.00553348292f },
	{ -2.85102231e-8f, .0770939664f, .0230258546f },
	{ -4.5975437e-8f, .0612891595f, .0195370861f },
	{ 2.63687901e-5f, .0047559225f, .0309494062f },
	{ .0320638079f, .0538020513f, .0758688308f },
	{ -.0322244017f, .05361869f, .0755823359f },
	{ .0162165175f, .232371641f, .0511341324f },
	{ .149198457f, 2.19397873e-8f, -.0550232576f },
	{ .287393078f, 2.50268389e-9f, -2.58787737e-5f },
	{ .270939812f, -7.06625108e-9f, 2.60897248e-5f },
	{ .122686267f, -.0322017573f, .0483306876f },
	{ .190119595f, -.00312878387f, -.000339570373f },
	{ -.0138011824f, .231803086f, .0521415786f },
	{ -.150371962f, 1.17387901e-7f, -.0554560437f },
	{ -.287366393f, 1.87628082e-8f, -2.59709359e-5f },
	{ -.271336198f, -1.16767401e-9f, 2.61269368e-5f },
	{ -.122642483f, -.0321145448f, .0480403904f },
	{ -.190005945f, -.00306615542f, -.0003157343f },
	{ .10043214f, -.0843452671f, .0259565473f },
	{ -1e-8f, -.432217537f, -.00802912805f },
	{ 1e-8f, -.421550959f, -.0348152298f },
	{ 0.0f, -.0505947206f, .132315294f },
	{ -.10047278f, -.0829525995f, .0262031695f },
	{ 1e-8f, -.433622059f, -.00805555828f },
	{ 2e-8f, -.421173943f, -.0347839785f },
	{ -3.42907669e-9f, -.0507960932f, .132841956f }
};

const float LIMB_RADIUS[30] = {
	0.000f, 0.115f, 0.125f, 0.130f, 0.055f, 0.050f,
	0.050f, 0.030f, 0.015f, 0.015f, 0.065f, 0.058f,
	0.050f, 0.042f, 0.018f, 0.018f, 0.065f, 0.058f,
	0.050f, 0.042f, 0.018f, 0.018f, 0.085f, 0.075f,
	0.058f, 0.042f, 0.085f, 0.075f, 0.058f, 0.042f
};

} // namespace soma30

namespace g1skel34 {

const int PARENT[34] = {
	-1, 0, 1, 2, 3, 4, 5, 6, 0, 8, 9, 10, 11, 12, 13, 0, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 17, 26, 27, 28, 29, 30, 31, 32
};

const char *const JOINT_NAME[34] = {
	"pelvis_skel", "left_hip_pitch_skel", "left_hip_roll_skel", "left_hip_yaw_skel",
	"left_knee_skel", "left_ankle_pitch_skel", "left_ankle_roll_skel", "left_toe_base",
	"right_hip_pitch_skel", "right_hip_roll_skel", "right_hip_yaw_skel", "right_knee_skel",
	"right_ankle_pitch_skel", "right_ankle_roll_skel", "right_toe_base", "waist_yaw_skel",
	"waist_roll_skel", "waist_pitch_skel", "left_shoulder_pitch_skel", "left_shoulder_roll_skel",
	"left_shoulder_yaw_skel", "left_elbow_skel", "left_wrist_roll_skel", "left_wrist_pitch_skel",
	"left_wrist_yaw_skel", "left_hand_roll_skel", "right_shoulder_pitch_skel", "right_shoulder_roll_skel",
	"right_shoulder_yaw_skel", "right_elbow_skel", "right_wrist_roll_skel", "right_wrist_pitch_skel",
	"right_wrist_yaw_skel", "right_hand_roll_skel"
};

const char *const HUMANOID_NAME[34] = {
	"Hips", "", "", "LeftUpperLeg",
	"LeftLowerLeg", "", "LeftFoot", "LeftToes",
	"", "", "RightUpperLeg", "RightLowerLeg",
	"", "RightFoot", "RightToes", "",
	"", "Spine", "", "",
	"LeftUpperArm", "LeftLowerArm", "", "",
	"LeftHand", "", "", "",
	"RightUpperArm", "RightLowerArm", "", "",
	"RightHand", ""
};

const int SIDE[34] = {
	SIDE_CENTER, SIDE_LEFT, SIDE_LEFT, SIDE_LEFT, SIDE_LEFT, SIDE_LEFT,
	SIDE_LEFT, SIDE_LEFT, SIDE_RIGHT, SIDE_RIGHT, SIDE_RIGHT, SIDE_RIGHT,
	SIDE_RIGHT, SIDE_RIGHT, SIDE_RIGHT, SIDE_CENTER, SIDE_CENTER, SIDE_CENTER,
	SIDE_LEFT, SIDE_LEFT, SIDE_LEFT, SIDE_LEFT, SIDE_LEFT, SIDE_LEFT,
	SIDE_LEFT, SIDE_LEFT, SIDE_RIGHT, SIDE_RIGHT, SIDE_RIGHT, SIDE_RIGHT,
	SIDE_RIGHT, SIDE_RIGHT, SIDE_RIGHT, SIDE_RIGHT
};

const float REST_OFFSET[34][3] = {
	{ 0.0f, 0.0f, 0.0f },
	{ .064452f, -.1027f, 0.0f },
	{ .052f, -.030465f, 0.0f },
	{ 0.0f, -.12412f, .025001f },
	{ .0021489f, -.17734f, -.078273f },
	{ -.000094445f, -.30001f, 0.0f },
	{ 0.0f, -.017558f, 0.0f },
	{ 0.0f, -.035f, .14f },
	{ -.064452f, -.1027f, 0.0f },
	{ -.052f, -.030465f, 0.0f },
	{ 0.0f, -.12412f, .025001f },
	{ -.0021489f, -.17734f, -.078273f },
	{ .000094445f, -.30001f, 0.0f },
	{ 0.0f, -.017558f, 0.0f },
	{ 0.0f, -.035f, .14f },
	{ 0.0f, 0.0f, 0.0f },
	{ 0.0f, .044f, -.0039635f },
	{ 0.0f, 0.0f, 0.0f },
	{ .10022f, .24778f, .0039563f },
	{ .038f, -.013831f, 0.0f },
	{ .00624f, -.1032f, 0.0f },
	{ 0.0f, -.080518f, .015783f },
	{ .00188791f, -.01f, .1f },
	{ 0.0f, 0.0f, .038f },
	{ 0.0f, 0.0f, .046f },
	{ 0.0f, 0.0f, .1f },
	{ -.10021f, .24778f, .0039563f },
	{ -.038f, -.013831f, 0.0f },
	{ -.00624f, -.1032f, 0.0f },
	{ 0.0f, -.080518f, .015783f },
	{ -.00188791f, -.01f, .1f },
	{ 0.0f, 0.0f, .038f },
	{ 0.0f, 0.0f, .046f },
	{ 0.0f, 0.0f, .1f }
};

const float LIMB_RADIUS[34] = {
	0.000f, 0.060f, 0.055f, 0.055f, 0.050f, 0.040f,
	0.035f, 0.030f, 0.060f, 0.055f, 0.055f, 0.050f,
	0.040f, 0.035f, 0.030f, 0.090f, 0.090f, 0.095f,
	0.050f, 0.045f, 0.042f, 0.038f, 0.032f, 0.030f,
	0.028f, 0.028f, 0.050f, 0.045f, 0.042f, 0.038f,
	0.032f, 0.030f, 0.028f, 0.028f
};

} // namespace g1skel34

const Definition DEFINITION[] = {
	{ "smplx22", "SMPL-X", 22, smplx22::PARENT, smplx22::JOINT_NAME, smplx22::HUMANOID_NAME,
	  smplx22::SIDE, smplx22::REST_OFFSET, smplx22::LIMB_RADIUS, 15 },
	{ "soma30", "SOMA", 30, soma30::PARENT, soma30::JOINT_NAME, soma30::HUMANOID_NAME,
	  soma30::SIDE, soma30::REST_OFFSET, soma30::LIMB_RADIUS, 6 },
	{ "g1skel34", "Unitree G1", 34, g1skel34::PARENT, g1skel34::JOINT_NAME, g1skel34::HUMANOID_NAME,
	  g1skel34::SIDE, g1skel34::REST_OFFSET, g1skel34::LIMB_RADIUS, -1 },
};

constexpr int DEFINITION_COUNT = int(sizeof(DEFINITION) / sizeof(DEFINITION[0]));

} // namespace

const Definition &smplx22() {
	return DEFINITION[0];
}

const Definition *by_joint_count(int p_joints) {
	for (const Definition &definition : DEFINITION) {
		if (definition.joint_count == p_joints) {
			return &definition;
		}
	}
	return nullptr;
}

const Definition *by_key(const char *p_key) {
	if (p_key == nullptr) {
		return nullptr;
	}
	for (const Definition &definition : DEFINITION) {
		if (std::strcmp(definition.key, p_key) == 0) {
			return &definition;
		}
	}
	return nullptr;
}

int count() {
	return DEFINITION_COUNT;
}

void rest_positions(const Definition &p_definition, godot::Vector3 *r_out) {
	for (int joint = 0; joint < p_definition.joint_count; ++joint) {
		const int parent = p_definition.parent[joint];
		r_out[joint] = parent < 0 ? godot::Vector3() : r_out[parent] + p_definition.offset(joint);
	}
}

double rest_height(const Definition &p_definition) {
	godot::Vector3 rest[MAX_JOINTS];
	rest_positions(p_definition, rest);
	double low = rest[0].y;
	double high = rest[0].y;
	for (int joint = 1; joint < p_definition.joint_count; ++joint) {
		low = low < rest[joint].y ? low : rest[joint].y;
		high = high > rest[joint].y ? high : rest[joint].y;
	}
	return high - low;
}

double ground_offset(const Definition &p_definition) {
	godot::Vector3 rest[MAX_JOINTS];
	rest_positions(p_definition, rest);
	double low = rest[0].y;
	for (int joint = 1; joint < p_definition.joint_count; ++joint) {
		low = low < rest[joint].y ? low : rest[joint].y;
	}
	return -low;
}

const Definition *at(int p_index) {
	return p_index >= 0 && p_index < DEFINITION_COUNT ? &DEFINITION[p_index] : nullptr;
}

} // namespace skeletons
