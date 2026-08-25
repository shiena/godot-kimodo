#include "smplx22.h"

namespace smplx22 {

const int PARENT[JOINT_COUNT] = {
	-1, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 9, 9, 12, 13, 14, 16, 17, 18, 19
};

const char *const JOINT_NAME[JOINT_COUNT] = {
	"pelvis", "left_hip", "right_hip", "spine1",
	"left_knee", "right_knee", "spine2", "left_ankle",
	"right_ankle", "spine3", "left_foot", "right_foot",
	"neck", "left_collar", "right_collar", "head",
	"left_shoulder", "right_shoulder", "left_elbow", "right_elbow",
	"left_wrist", "right_wrist"
};

// SkeletonProfileHumanoid bone names, used by the retargeting stage.
const char *const HUMANOID_NAME[JOINT_COUNT] = {
	"Hips", "LeftUpperLeg", "RightUpperLeg", "Spine",
	"LeftLowerLeg", "RightLowerLeg", "Chest", "LeftFoot",
	"RightFoot", "UpperChest", "LeftToes", "RightToes",
	"Neck", "LeftShoulder", "RightShoulder", "Head",
	"LeftUpperArm", "RightUpperArm", "LeftLowerArm", "RightLowerArm",
	"LeftHand", "RightHand"
};

const int SIDE[JOINT_COUNT] = {
	SIDE_CENTER, SIDE_LEFT, SIDE_RIGHT, SIDE_CENTER,
	SIDE_LEFT, SIDE_RIGHT, SIDE_CENTER, SIDE_LEFT,
	SIDE_RIGHT, SIDE_CENTER, SIDE_LEFT, SIDE_RIGHT,
	SIDE_CENTER, SIDE_LEFT, SIDE_RIGHT, SIDE_CENTER,
	SIDE_LEFT, SIDE_RIGHT, SIDE_LEFT, SIDE_RIGHT,
	SIDE_LEFT, SIDE_RIGHT
};

const float REST_OFFSET[JOINT_COUNT][3] = {
	{ 0.0f, 0.0f, 0.0f },
	{ 0.052299f, -0.093936f, -0.027607f },
	{ -0.057193f, -0.106548f, -0.022218f },
	{ -0.001496f, 0.112930f, -0.024981f },
	{ 0.058867f, -0.416442f, -0.006557f },
	{ -0.048074f, -0.397560f, -0.014061f },
	{ 0.006900f, 0.145636f, -0.006859f },
	{ -0.041738f, -0.437584f, -0.029512f },
	{ 0.014489f, -0.446853f, -0.018030f },
	{ -0.010334f, 0.056082f, 0.021116f },
	{ 0.049294f, -0.065279f, 0.126259f },
	{ -0.040575f, -0.065287f, 0.127076f },
	{ -0.011026f, 0.171365f, -0.028827f },
	{ 0.047725f, 0.087643f, -0.008375f },
	{ -0.046636f, 0.086612f, -0.014864f },
	{ 0.024654f, 0.175391f, 0.024463f },
	{ 0.126285f, 0.057680f, -0.013885f },
	{ -0.109342f, 0.053674f, -0.009118f },
	{ 0.272907f, -0.069853f, -0.039094f },
	{ -0.292029f, -0.035440f, -0.024565f },
	{ 0.276174f, 0.021254f, -0.002478f },
	{ -0.271878f, -0.004835f, -0.016445f }
};

const float LIMB_RADIUS[JOINT_COUNT] = {
	0.000f, // pelvis, unused
	0.085f, 0.085f, // hips
	0.115f, // spine1
	0.075f, 0.075f, // knees
	0.125f, // spine2
	0.058f, 0.058f, // ankles
	0.130f, // spine3
	0.042f, 0.042f, // toes
	0.055f, // neck
	0.065f, 0.065f, // collars
	0.050f, // head
	0.058f, 0.058f, // shoulders
	0.050f, 0.050f, // elbows
	0.042f, 0.042f // wrists
};

} // namespace smplx22
