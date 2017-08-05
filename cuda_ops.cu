#include "cuda_ops.h"
#include <stdio.h>

// kernels
namespace kernels {

#if __CUDA_ARCH__ < 600
__device__ double atomicAdd(double* address, double val) {
	unsigned long long int* address_as_ull = (unsigned long long int*)address;
	unsigned long long int old = *address_as_ull, assumed;
	do {
		assumed = old;
		old = atomicCAS(address_as_ull, assumed,
				__double_as_longlong(val + __longlong_as_double(assumed)));
	} while (assumed != old);
	return __longlong_as_double(old);
}
#endif

__global__ void compute_weights(float local,
								double * distances,
								unsigned int deformed_points_count,
								unsigned int triangles_count,
								double *weights,
								double *weights_sums) {
	unsigned int i = blockIdx.x * blockDim.x + threadIdx.x;
	unsigned int j = blockIdx.y * blockDim.y + threadIdx.y;
	if (i >= deformed_points_count || j >= triangles_count)
		return;
	double distance = distances[i * triangles_count + j];
	weights[i * triangles_count + j] = 1 / (1 + pow(distance, (double)local));
	weights_sums[i] = 0;
};

__global__ void sum_weights(unsigned int deformed_points_count,
							unsigned int triangles_count,
							double *weights,
							double *weights_sums) {
	unsigned int i = blockIdx.x * blockDim.x + threadIdx.x;
	unsigned int j = blockIdx.y * blockDim.y + threadIdx.y;
	if (i >= deformed_points_count || j >= triangles_count)
		return;
	atomicAdd(&(weights_sums[i]),
			  weights[i * triangles_count + j]);
};

__global__ void normalise_weights(unsigned int deformed_points_count,
								  unsigned int triangles_count,
								  double *weights,
								  double *weights_sums,
								  double *normalised_weights) {
	unsigned int i = blockIdx.x * blockDim.x + threadIdx.x;
	unsigned int j = blockIdx.y * blockDim.y + threadIdx.y;
	if (i >= deformed_points_count || j >= triangles_count)
		return;
	unsigned int offset = i * triangles_count + j;
	normalised_weights[offset] = weights[offset] / weights_sums[i];
};

__device__ double3 double3_sub(double3 a, double3 b) {
	return make_double3(a.x - b.x, a.y - b.y, a.z - b.z);
}

__device__ double3 double3_cross(double3 a, double3 b) {
	return make_double3(a.y * b.z - a.z * b.y,
						a.z * b.x - a.x * b.z,
						a.x * b.y - a.y * b.x);
}

__device__ double double3_dot(double3 a, double3 b) {
	return a.x * b.x + a.y * b.y + a.z * b.z;;
}

__device__ double double3_inv_length(double3 v) {
	return rsqrt(double3_dot(v, v));
}

__device__ double3 double3_double_mult(double3 a, double b) {
    return make_double3(a.x * b, a.y * b, a.z * b);
}

__global__ void create_def_matrices(
			unsigned int triangles_count,
			unsigned int *triangles_indices,
			double *vertices,
			double *res,
			bool inverse
) {
	unsigned int i = blockIdx.x * blockDim.x + threadIdx.x;
	if (i >= triangles_count)
		return;
	unsigned int index_A = triangles_indices[i * 3] * 3;
	unsigned int index_C = triangles_indices[i * 3 + 1] * 3;
	unsigned int index_B = triangles_indices[i * 3 + 2] * 3;
		
	double3 A = make_double3(
		vertices[index_A],
		vertices[index_A + 1],
		vertices[index_A + 2]
	);
	double3 B = make_double3(
		vertices[index_B],
		vertices[index_B + 1],
		vertices[index_B + 2]
	);
	double3 C = make_double3(
		vertices[index_C],
		vertices[index_C + 1],
		vertices[index_C + 2]
	);
	double3 E1 = double3_sub(C, A);
	double3 E2 = double3_sub(B, A);
	double3 E1_E2_cross = double3_cross(E1, E2);
	double cross_inv_len = double3_inv_length(E1_E2_cross);

	if (isinf(cross_inv_len)) cross_inv_len = 1;
	double3 E3 = double3_double_mult(E1_E2_cross, cross_inv_len);

	// store matrices in the column-major order
	unsigned int j = i * 9;

	if (!inverse) {
		res[j] = E1.x;
		res[j + 3] = E1.y;
		res[j + 6] = E1.z;
		res[j + 1] = E2.x;
		res[j + 4] = E2.y;
		res[j + 7] = E2.z;
		res[j + 2] = E3.x;
		res[j + 5] = E3.y;
		res[j + 8] = E3.z;
	} else {
		double m_0_0 = E1.x;
		double m_1_0 = E1.y;
		double m_2_0 = E1.z;
		double m_0_1 = E2.x;
		double m_1_1 = E2.y;
		double m_2_1 = E2.z;
		double m_0_2 = E3.x;
		double m_1_2 = E3.y;
		double m_2_2 = E3.z;

		double det = (
			m_0_0 * (m_1_1 * m_2_2 - m_2_1 * m_1_2) -
			m_0_1 * (m_1_0 * m_2_2 - m_1_2 * m_2_0) +
			m_0_2 * (m_1_0 * m_2_1 - m_1_1 * m_2_0)
		);
		double invdet = 1 / det;
	
		double res_0_0 = (m_1_1 * m_2_2 - m_2_1 * m_1_2) * invdet;
		double res_0_1 = (m_0_2 * m_2_1 - m_0_1 * m_2_2) * invdet;
		double res_0_2 = (m_0_1 * m_1_2 - m_0_2 * m_1_1) * invdet;
		double res_1_0 = (m_1_2 * m_2_0 - m_1_0 * m_2_2) * invdet;
		double res_1_1 = (m_0_0 * m_2_2 - m_0_2 * m_2_0) * invdet;
		double res_1_2 = (m_1_0 * m_0_2 - m_0_0 * m_1_2) * invdet;
		double res_2_0 = (m_1_0 * m_2_1 - m_2_0 * m_1_1) * invdet;
		double res_2_1 = (m_2_0 * m_0_1 - m_0_0 * m_2_1) * invdet;
		double res_2_2 = (m_0_0 * m_1_1 - m_1_0 * m_0_1) * invdet;
	
		res[j] = res_0_0;
		res[j + 3] = res_0_1;
		res[j + 6] = res_0_2;
		res[j + 1] = res_1_0;
		res[j + 4] = res_1_1;
		res[j + 7] = res_1_2;
		res[j + 2] = res_2_0;
		res[j + 5] = res_2_1;
		res[j + 8] = res_2_2;
	}
};


__device__ double3 double3_add(double3 a, double3 b) {
	return make_double3(a.x + b.x, a.y + b.y, a.z + b.z);
}

__global__ void apply_deform(unsigned int deformed_points_count,
							 unsigned int triangles_count,
							 double *deformed_points,
							 double *mats,
							 double *cs_pts,
							 double *normalised_weights,
							 double *res_points)
{
	unsigned int i = blockIdx.x * blockDim.x + threadIdx.x;
	unsigned int j = blockIdx.y * blockDim.y + threadIdx.y;
	if (i >= deformed_points_count || j >= triangles_count)
		return;
	/*
	double3 point = make_double3(
		deformed_points[i],
		deformed_points[i + 1],
		deformed_points[i + 2]
	);
	*/
	unsigned int w_offset = i * triangles_count + j;
	unsigned int c_offset = i * triangles_count * 3 + j * 3;
	double weight = normalised_weights[w_offset];
	double3 cs_point = make_double3(
		cs_pts[c_offset],
		cs_pts[c_offset + 1],
		cs_pts[c_offset + 2]
	);

	// multiply by matrix
	unsigned int k = j * 9;
	double x = (
		mats[k + 0] * cs_point.x +
		mats[k + 1] * cs_point.y +
		mats[k + 2] * cs_point.z
	);
	double y = (
		mats[k + 3] * cs_point.x +
		mats[k + 4] * cs_point.y +
		mats[k + 5] * cs_point.z
	);
	double z = (
		mats[k + 6] * cs_point.x +
		mats[k + 7] * cs_point.y +
		mats[k + 8] * cs_point.z
	);
	double3 control_point = make_double3(
		x * weight,
		y * weight,
		z * weight
	);

	atomicAdd(&(res_points[i * 3]), control_point.x);
	atomicAdd(&(res_points[i * 3 + 1]), control_point.y);
	atomicAdd(&(res_points[i * 3 + 2]), control_point.z);
};

__global__ void compute_cs_points(unsigned int deformed_points_count,
							 unsigned int triangles_count,
							 double *deformed_points,
							 double *mats,
							 double *cs_pts) {

	unsigned int i = blockIdx.x * blockDim.x + threadIdx.x;
	unsigned int j = blockIdx.y * blockDim.y + threadIdx.y;
	if (i >= deformed_points_count || j >= triangles_count)
		return;

	double3 point = make_double3(
		deformed_points[i],
		deformed_points[i + 1],
		deformed_points[i + 2]
	);

	unsigned int k = j * 9;
	double x = (
		mats[k + 0] * point.x +
		mats[k + 1] * point.y +
		mats[k + 2] * point.z
	);
	double y = (
		mats[k + 3] * point.x +
		mats[k + 4] * point.y +
		mats[k + 5] * point.z
	);
	double z = (
		mats[k + 6] * point.x +
		mats[k + 7] * point.y +
		mats[k + 8] * point.z
	);

	unsigned int c_offset = i * triangles_count * 3 + j * 3;
	cs_pts[c_offset] = x;
	cs_pts[c_offset + 1] = y;
	cs_pts[c_offset + 2] = z;
}


}

// wrappers
int CudaDeviceCount()
{
	int deviceCount = 0;
	cudaGetDeviceCount(&deviceCount);
	return deviceCount;
};

void CudaComputeWeights(
	double *normalised_weights,
	double *contol_space_points,
	float local,
	double *distances,
	double *points,
	unsigned int deformed_points_count,
	unsigned int triangles_count,
	unsigned int *triangles_indices,
	double *ref_vertices_cu,
	unsigned int ref_vertices_count,
	double *reference_matrices_cu
) {
	cudaError_t error;

	unsigned int grid_area = deformed_points_count * triangles_count;
	// internal vars
	double *d_weights_sums;
	error = cudaMalloc((void **)&d_weights_sums,
			   sizeof(double) * deformed_points_count);
	cudaMemset(d_weights_sums, 0, sizeof(double) * deformed_points_count);

	double *d_weights;
	error = cudaMalloc((void **)&d_weights, sizeof(double) * grid_area);
	cudaMemset(d_weights, 0, sizeof(double) * grid_area);

	// output vars
	double *d_normalised_weights;
	error = cudaMalloc((void **)&d_normalised_weights,
					   sizeof(double) * grid_area);
	cudaMemset(d_normalised_weights, 0, sizeof(double) * grid_area);

	// input vars
	double *d_distances;
	error = cudaMalloc((void **)&d_distances, sizeof(double) * grid_area);
	error = cudaMemcpy(d_distances, distances, sizeof(double) * grid_area,
			   		   cudaMemcpyHostToDevice);

	dim3 threadsPerBlock(8, 8);
	dim3 numBlocks(deformed_points_count / threadsPerBlock.x + 1,
				   triangles_count / threadsPerBlock.y + 1);

	
	double *d_points;
	error = cudaMalloc((void **)&d_points,
					   sizeof(double) * deformed_points_count * 3);
	error = cudaMemcpy(d_points, points,
					   sizeof(double) * deformed_points_count * 3,
					   cudaMemcpyHostToDevice);
	if(error != cudaSuccess)
		printf("cpy pts: %s\n", cudaGetErrorString(error));

	unsigned int *d_triangles_indices;
	error = cudaMalloc((void **)&d_triangles_indices,
					   sizeof(unsigned int) * triangles_count * 3);
	error = cudaMemcpy(d_triangles_indices, triangles_indices,
					   sizeof(unsigned int) * triangles_count * 3,
					   cudaMemcpyHostToDevice);
	if(error != cudaSuccess)
		printf("cpy indices: %s\n", cudaGetErrorString(error));

	double *d_ref_vertices_cu;
	error = cudaMalloc((void **)&d_ref_vertices_cu,
					   sizeof(double) * ref_vertices_count * 3);
	error = cudaMemcpy(d_ref_vertices_cu, ref_vertices_cu,
					   sizeof(double) * ref_vertices_count * 3,
					   cudaMemcpyHostToDevice);
	double *d_mats;
	error = cudaMalloc((void **)&d_mats,
			   sizeof(double) * triangles_count * 9);
	cudaMemset(d_mats, 0, sizeof(double) * triangles_count * 9);

	double *d_cs_points;
	error = cudaMalloc((void **)&d_cs_points, sizeof(double) * grid_area * 3);
	cudaMemset(d_cs_points, 0, sizeof(double) * grid_area * 3);


	if(error != cudaSuccess)
		printf("cpy drv verts: %s\n", cudaGetErrorString(error));
	
	dim3 threadsMatPerBlock(64, 1);
	dim3 numMatBlocks(triangles_count / threadsMatPerBlock.x + 1, 1);
	kernels::create_def_matrices<<<numMatBlocks, threadsMatPerBlock>>>(
		triangles_count,
		d_triangles_indices,
		d_ref_vertices_cu,
		d_mats,
		true
	);
	if(error != cudaSuccess)
		printf("create_def_matrices: %s\n", cudaGetErrorString(error));
	
	kernels::compute_cs_points<<<numBlocks, threadsPerBlock>>>(
		deformed_points_count, triangles_count, d_points,
		d_mats, d_cs_points 
	);

	kernels::compute_weights<<<numBlocks, threadsPerBlock>>>(
		local, d_distances, deformed_points_count, triangles_count, d_weights, d_weights_sums
	);
	error = cudaGetLastError();
	if(error != cudaSuccess)
		printf("Compute weights: %s\n", cudaGetErrorString(error));
	
	kernels::sum_weights<<<numBlocks, threadsPerBlock>>>(
		deformed_points_count, triangles_count, d_weights, d_weights_sums
	);
	error = cudaGetLastError();
	if(error != cudaSuccess)
		printf("Sum weights: %s\n", cudaGetErrorString(error));

	kernels::normalise_weights<<<numBlocks, threadsPerBlock>>>(
		deformed_points_count, triangles_count, d_weights,
		d_weights_sums, d_normalised_weights 
	);
	if(error != cudaSuccess)
		printf("Normalise weights: %s\n", cudaGetErrorString(error));

	error = cudaGetLastError();

	error = cudaMemcpy(normalised_weights, d_normalised_weights,
			   sizeof(double) * deformed_points_count * triangles_count,
			   cudaMemcpyDeviceToHost);

	error = cudaMemcpy(contol_space_points, d_cs_points,
			   sizeof(double) * grid_area * 3,
			   cudaMemcpyDeviceToHost);

	if(error != cudaSuccess)
		printf("MemCpy DevToHost: %s\n", cudaGetErrorString(error));

	cudaFree(d_distances);
	cudaFree(d_weights);
	cudaFree(d_weights_sums);
	cudaFree(d_normalised_weights);
	cudaFree(d_points);
	cudaFree(d_triangles_indices);
	cudaFree(d_ref_vertices_cu);
	cudaFree(d_mats);
	cudaFree(d_cs_points);
};


void CudaApplyDeform(
	double *out_points,
	double *cs_points,
	double *points,
	unsigned int deformed_points_count,
	unsigned int *triangles_indices,
	unsigned int triangles_count,
	double *driver_vertices_cu,
	unsigned int driver_vertices_count,
	double *normalised_weights,
	double *mats
) {
	cudaError_t error;
	unsigned int grid_area = deformed_points_count * triangles_count;
	
	// out vars
	double *d_out_points;
	error = cudaMalloc((void **)&d_out_points,
			   sizeof(double) * deformed_points_count * 3);
	cudaMemset(d_out_points, 0, sizeof(double) * deformed_points_count * 3);
	if(error != cudaSuccess)
		printf("outs: %s\n", cudaGetErrorString(error));
	
	// internal vars
	double *d_mats;
	error = cudaMalloc((void **)&d_mats,
			   sizeof(double) * triangles_count * 9);
	cudaMemset(d_mats, 0, sizeof(double) * triangles_count * 9);
	
	/*
	if(error != cudaSuccess)
		printf("mats: %s\n", cudaGetErrorString(error));
	error = cudaMemcpy(d_mats, mats,
						sizeof(double) * triangles_count * 9,
					   cudaMemcpyHostToDevice);
	*/
	// in vars
	double *d_cs_points;
	error = cudaMalloc((void **)&d_cs_points, sizeof(double) * grid_area * 3);
	error = cudaMemcpy(d_cs_points, cs_points, sizeof(double) * grid_area * 3,
					   cudaMemcpyHostToDevice);
	double *d_points;
	error = cudaMalloc((void **)&d_points,
					   sizeof(double) * deformed_points_count * 3);
	error = cudaMemcpy(d_points, points,
					   sizeof(double) * deformed_points_count * 3,
					   cudaMemcpyHostToDevice);
	if(error != cudaSuccess)
		printf("cpy pts: %s\n", cudaGetErrorString(error));

	unsigned int *d_triangles_indices;
	error = cudaMalloc((void **)&d_triangles_indices,
					   sizeof(unsigned int) * triangles_count * 3);
	error = cudaMemcpy(d_triangles_indices, triangles_indices,
					   sizeof(unsigned int) * triangles_count * 3,
					   cudaMemcpyHostToDevice);
	if(error != cudaSuccess)
		printf("cpy indices: %s\n", cudaGetErrorString(error));

	double *d_driver_vertices_cu;
	error = cudaMalloc((void **)&d_driver_vertices_cu,
					   sizeof(double) * driver_vertices_count * 3);
	error = cudaMemcpy(d_driver_vertices_cu, driver_vertices_cu,
					   sizeof(double) * driver_vertices_count * 3,
					   cudaMemcpyHostToDevice);
	if(error != cudaSuccess)
		printf("cpy drv verts: %s\n", cudaGetErrorString(error));

	double *d_normalised_weights;
	error = cudaMalloc((void **)&d_normalised_weights,
					   sizeof(double) * grid_area);
	error = cudaMemcpy(d_normalised_weights, normalised_weights,
					   sizeof(double) * grid_area,
					   cudaMemcpyHostToDevice);
	if(error != cudaSuccess)
		printf("cpy norm weights: %s\n", cudaGetErrorString(error));
	
	dim3 threadsMatPerBlock(64, 1);
	dim3 numMatBlocks(triangles_count / threadsMatPerBlock.x + 1, 1);

	kernels::create_def_matrices<<<numMatBlocks, threadsMatPerBlock>>>(
		triangles_count,
		d_triangles_indices,
		d_driver_vertices_cu,
		d_mats,
		false
	);

	error = cudaGetLastError();
	if(error != cudaSuccess)
		printf("Create def mats: %s\n", cudaGetErrorString(error));

	dim3 threadsPerBlock(8, 8);
	dim3 numBlocks(deformed_points_count / threadsPerBlock.x + 1,
				   triangles_count / threadsPerBlock.y + 1);

	kernels::apply_deform<<<numBlocks, threadsPerBlock>>>(
		deformed_points_count,
		triangles_count,
		d_points,
		d_mats,
		d_cs_points,
		d_normalised_weights,
		d_out_points
	);
	error = cudaGetLastError();
	if(error != cudaSuccess)
		printf("Apply deform: %s\n", cudaGetErrorString(error));

	error = cudaMemcpy(out_points, d_out_points,
			   sizeof(double) * deformed_points_count * 3,
			   cudaMemcpyDeviceToHost);
	/*
	error = cudaMemcpy(mats, d_mats,
			   sizeof(double) * triangles_count * 9,
			   cudaMemcpyDeviceToHost);
	*/
	if(error != cudaSuccess)
		printf("Deform DevToHost: %s\n", cudaGetErrorString(error));

	cudaFree(d_out_points);
	cudaFree(d_mats);
	cudaFree(d_cs_points);
	cudaFree(d_points);
	cudaFree(d_triangles_indices);
	cudaFree(d_driver_vertices_cu);
	cudaFree(d_normalised_weights);
};
