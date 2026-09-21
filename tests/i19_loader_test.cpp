#include <cassert>
#include <framework/Loader.h>
#include <fstream>
#include <sstream>
int main(int argc, char **argv) {
  if (argc != 2)
    return 1;
  {
    std::ofstream f(argv[1]);
    f << "1 9\n9 1\n";
  }
  Loader<uint32_t> loader(argv[1], true);
  return loader.m_batch_size.size() != 2 || loader.m_batch_size[0].first != 1 ||
         loader.m_batch_size[0].second != 9 ||
         loader.m_batch_size[1].first != 9 ||
         loader.m_batch_size[1].second != 1 || loader.m_add_size != 10 ||
         loader.m_del_size != 10;
}
