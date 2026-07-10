#include <mpi.h>

#include <cstdio>

int main(int argc, char** argv) {
  MPI_Init(&argc, &argv);
  int rank = 0;
  int size = 0;
  MPI_Comm_rank(MPI_COMM_WORLD, &rank);
  MPI_Comm_size(MPI_COMM_WORLD, &size);

  int value = rank;
  if (size < 2) {
    std::printf("rank %d/%d single-process MPI smoke\n", rank, size);
  } else if (rank == 0) {
    MPI_Send(&value, 1, MPI_INT, 1, 7, MPI_COMM_WORLD);
    MPI_Recv(&value, 1, MPI_INT, 1, 8, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
    std::printf("rank 0 received %d\n", value);
  } else if (rank == 1) {
    MPI_Recv(&value, 1, MPI_INT, 0, 7, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
    value += 100;
    MPI_Send(&value, 1, MPI_INT, 0, 8, MPI_COMM_WORLD);
    std::printf("rank 1 sent %d\n", value);
  }

  MPI_Barrier(MPI_COMM_WORLD);
  if (rank == 0) {
    std::puts("PASSED mpi_pingpong");
  }
  MPI_Finalize();
  return 0;
}
