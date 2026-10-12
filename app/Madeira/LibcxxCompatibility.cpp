#if defined(__APPLE__) && defined(__ENVIRONMENT_IPHONE_OS_VERSION_MIN_REQUIRED__) && \
    __ENVIRONMENT_IPHONE_OS_VERSION_MIN_REQUIRED__ < 170000
#define _LIBCPP_DISABLE_AVAILABILITY
#include <memory_resource>

_LIBCPP_BEGIN_NAMESPACE_STD
namespace pmr {
memory_resource::~memory_resource() = default;
}
_LIBCPP_END_NAMESPACE_STD
#endif
