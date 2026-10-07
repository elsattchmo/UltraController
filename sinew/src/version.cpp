#include "sinew/version.hpp"

#ifndef SINEW_BOX3D_COMMIT
#define SINEW_BOX3D_COMMIT "unknown"
#endif

namespace sinew {

const char* version_string() {
	return "sinew 0.1.0 (box3d " SINEW_BOX3D_COMMIT ")";
}

} // namespace sinew
