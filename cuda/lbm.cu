#define STB_IMAGE_IMPLEMENTATION
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image.h"
#include "stb_image_write.h"
#include <iostream>
#include <chrono>
#include <vector>
#include <algorithm>
#include <string>
#include <dirent.h>
#include <sys/stat.h>
#include <sys/types.h>
#include<cuda.h>
#include <cuda_runtime.h>
#include <immintrin.h>  // Include header for SIMD intrinsics
#include <fstream>


// loading cuda: module load cuda11/11.0
// Compile as:
// nvcc -o lbm lbm.cu -std=c++11


using namespace std;
// define gpu and cpu kernels 
// baseline
__global__ void compute_disparity_v0(int width, int height, int patch_size, int search_range, const unsigned char* left_gray, const unsigned char* right_gray, unsigned char* disparity) {



    int min_sad = INT_MAX;
    int best_offset = 0;

    // Compute the valid range of disparities for the current pixel
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;

		if (x >= patch_size/2 && x < width - patch_size/2 && y >= patch_size/2 && y < height - patch_size/2) {

			int min_disp_range = max(0, x - search_range);
    	int max_disp_range = min(width - 1, x + search_range);
		  // Iterate over all possible disparities
		  for (int offset = min_disp_range - x; offset <= max_disp_range - x; offset++) {
		      // Compute SAD between left and right block
		      int sad = 0;
		      for (int i = -patch_size/2; i <= patch_size/2; i++) {
		          for (int j = -patch_size/2; j <= patch_size/2; j++) {

				            int px1 = left_gray[(y + i) * width + (x + j)];
				            int px2 = right_gray[(y + i) * width + (x + offset + j)];
				            sad += abs(px1 - px2);
								
		          }
		      }

		      // Update best disparity if current SAD is lower
		      if (sad < min_sad) {
		          min_sad = sad;
		          best_offset = offset;
		      }
		  }

		  // Store best disparity
		  disparity[(y * width) + x] = abs(best_offset); 
		}
}

// shared memory for left image
__global__ void compute_disparity_v1(int width, int height, int patch_size, int search_range, const unsigned char* left_gray, const unsigned char* right_gray, unsigned char* disparity) {

    __shared__ unsigned char left_shared[64][64]; // padding shared memory enough to support getting SAD neighbors for the left image tiles  

    int min_sad = INT_MAX;
    int best_offset = 0;

    // Compute the valid range of disparities for the current pixel
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;

    // Load left image tile into shared memory
    for (int i = -patch_size/2; i <= patch_size/2; i++) {
        for (int j = -patch_size/2; j <= patch_size/2; j++) {
					// Compute the clamped x and y values to ensure that the indices used to access left_gray
					// are within the valid range of indices for the left image array
            int clamped_x = min(max(0, x + j), width - 1);
            int clamped_y = min(max(0, y + i), height - 1);
            left_shared[threadIdx.y + i + patch_size/2][threadIdx.x + j + patch_size/2] = left_gray[y * width + x];

        }
    }

    //__syncthreads();

    if (x >= patch_size/2 && x < width - patch_size/2 && y >= patch_size/2 && y < height - patch_size/2) {
        int min_disp_range = max(0, x - search_range);
        int max_disp_range = min(width - 1, x + search_range);

        // Iterate over all possible disparities
        for (int offset = min_disp_range - x; offset <= max_disp_range - x; offset++) {
            // Compute SAD between left and right block
            int sad = 0;
            for (int i = -patch_size/2; i <= patch_size/2; i++) {
                for (int j = -patch_size/2; j <= patch_size/2; j++) {
                    int px1 = left_shared[threadIdx.y + i + patch_size/2][threadIdx.x + j + patch_size/2];
                    int px2 = right_gray[(y + i) * width + (x + offset + j)];
                    sad += abs(px1 - px2);
                }
            }
						// __syncthreads();
            // Update best disparity if current SAD is lower
            if (sad < min_sad) {
                min_sad = sad;
                best_offset = offset;
            }
        }

        // Store best disparity
        disparity[(y * width) + x] = abs(best_offset);
    }
}


// early termination
__global__ void compute_disparity_v2(int width, int height, int patch_size, int search_range, const unsigned char* left_gray, const unsigned char* right_gray, unsigned char* disparity) {



    int min_sad = INT_MAX;
    int best_offset = 0;

    // Compute the valid range of disparities for the current pixel
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;

		if (x >= patch_size/2 && x < width - patch_size/2 && y >= patch_size/2 && y < height - patch_size/2) {

			int min_disp_range = max(0, x - search_range);
    	int max_disp_range = min(width - 1, x + search_range);
      // Iterate over all possible disparities
			int offset = min_disp_range - x; 	
        exit: while(offset <= max_disp_range - x){
		      // Compute SAD between left and right block
		      int sad = 0;
		      for (int i = -patch_size/2; i <= patch_size/2; i++) {
		          for (int j = -patch_size/2; j <= patch_size/2; j++) {

				            int px1 = left_gray[(y + i) * width + (x + j)];
				            int px2 = right_gray[(y + i) * width + (x + offset + j)];
				            sad += abs(px1 - px2);
								
		          }
							if(sad >= min_sad){
										offset++;
										goto exit;
								}
		      }

		      // Update best disparity if current SAD is lower
		      if (sad < min_sad) {
		          min_sad = sad;
		          best_offset = offset;
		      }
					offset++;
		  }

		  // Store best disparity
		  disparity[(y * width) + x] = abs(best_offset); 
		}
}

// shared memory for left image + early termination

__global__ void compute_disparity_v3(int width, int height, int patch_size, int search_range, const unsigned char* left_gray, const unsigned char* right_gray, unsigned char* disparity) {

    __shared__ unsigned char left_shared[64][64]; // padding shared memory enough to support getting SAD neighbors for the left image tiles  

    int min_sad = INT_MAX;
    int best_offset = 0;

    // Compute the valid range of disparities for the current pixel
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;

    // Load left image tile into shared memory
    for (int i = -patch_size/2; i <= patch_size/2; i++) {
        for (int j = -patch_size/2; j <= patch_size/2; j++) {
					// Compute the clamped x and y values to ensure that the indices used to access left_gray
					// are within the valid range of indices for the left image array
            int clamped_x = min(max(0, x + j), width - 1);
            int clamped_y = min(max(0, y + i), height - 1);
            left_shared[threadIdx.y + i + patch_size/2][threadIdx.x + j + patch_size/2] = left_gray[clamped_y * width + clamped_x];

        }
    }

    __syncthreads();

    if (x >= patch_size/2 && x < width - patch_size/2 && y >= patch_size/2 && y < height - patch_size/2) {
        int min_disp_range = max(0, x - search_range);
        int max_disp_range = min(width - 1, x + search_range);

        // Iterate over all possible disparities
				int offset = min_disp_range - x; 	
        exit: while(offset <= max_disp_range - x){
            // Compute SAD between left and right block
            int sad = 0;
            for (int i = -patch_size/2; i <= patch_size/2; i++) {
                for (int j = -patch_size/2; j <= patch_size/2; j++) {
                    int px1 = left_shared[threadIdx.y + i + patch_size/2][threadIdx.x + j + patch_size/2];
                    int px2 = right_gray[(y + i) * width + (x + offset + j)];
                    sad += abs(px1 - px2);
                }
								if(sad >= min_sad){
											offset++;
											goto exit;
									}

            }
						//__syncthreads();
						
            // Update best disparity if current SAD is lower
            if (sad < min_sad) {
                min_sad = sad;
                best_offset = offset;
            }
						offset++;
        }

        // Store best disparity
        disparity[(y * width) + x] = abs(best_offset);
    }
}


// tiled based workload mapping (will not be included in the presentation/report --> hard to explain)

__global__ void compute_disparity_v4(int width, int height, int patch_size, int search_range, const unsigned char* left_gray, const unsigned char* right_gray, unsigned char* disparity) {
    int tile_width = blockDim.x;
    int tile_height = blockDim.y;
    int tile_x = blockIdx.x * tile_width;
    int tile_y = blockIdx.y * tile_height;

    int x_start = tile_x + threadIdx.x;
    int y_start = tile_y + threadIdx.y;

    for (int y = y_start; y < tile_y + tile_height && y < height - patch_size/2 && y >=patch_size/2; y += blockDim.y) {
        for (int x = x_start; x < tile_x + tile_width && x < width - patch_size/2 && x >=patch_size/2; x += blockDim.x) {

            int min_disp_range = max(0, x - search_range);
            int max_disp_range = min(width - 1, x + search_range);

            int min_sad = INT_MAX;
            int best_offset = 0;
						int offset = min_disp_range - x; 	
            exit: while(offset <= max_disp_range - x){
                int sad = 0;
                for (int i = -patch_size/2; i <= patch_size/2; i++) {
                    for (int j = -patch_size/2; j <= patch_size/2; j++) {
                        int px1 = left_gray[(y + i) * width + (x + j)];
                        int px2 = right_gray[(y + i) * width + (x + offset + j)];
                        sad += abs(px1 - px2);

                    }
												if(min_sad <= sad){
														offset++;
														goto exit;
												}
                }

                if (sad < min_sad) {
                    min_sad = sad;
                    best_offset = offset;
                }
								offset++;
            }

            disparity[y * width + x] = abs(best_offset);
        }
    }
}








// Function to convert RGB image to grayscale
void rgb2gray(unsigned char* rgb_img, int img_width, int img_height, unsigned char* gray_img)
{
    for (int i = 0; i < img_width * img_height; i++) {
        int r = rgb_img[3 * i];
        int g = rgb_img[3 * i + 1];
        int b = rgb_img[3 * i + 2];
        gray_img[i] = (unsigned char)(0.299 * r + 0.587 * g + 0.114 * b);
    }
}

// Function to normalize image for visualization
void normalize_image(unsigned char* img, int img_width, int img_height)
{
  	vector<unsigned char> img_vec(img, img + img_width * img_height);
    auto minmax = minmax_element(img_vec.begin(), img_vec.end());
    int min_val = *minmax.first;
    int max_val = *minmax.second;
    for (int i = 0; i < img_width * img_height; i++) {
        img[i] = (unsigned char)(255.0 * (img[i] - min_val) / (max_val - min_val));
    }
}

int main(int argc, char** argv)
{
		// Check command line arguments
		if (argc != 6) {
				cerr << "Usage: " << argv[0] << "<kernel_version> <gpu_patch_size> <cost block size> <search range> <image directory>" << endl;
				return 1;
		}


    // Parse block size and search range from command line arguments
		int kernel_version = atoi(argv[1]);
		int gpu_block_dim = atoi(argv[2]);
    int patch_size = atoi(argv[3]);
    int search_range = atoi(argv[4]);
 		string image_dir = argv[5];
   	string left_path = image_dir + "/view5.png";
   	string right_path = image_dir + "/view1.png";
		typedef void (*kernel_function_t)(int, int, int, int, const unsigned char*, const unsigned char*, unsigned char*);

		kernel_function_t kernel_functions[] = {
				compute_disparity_v0, // baseline
				compute_disparity_v1, // shared memory only
				compute_disparity_v2, // early termination only
				compute_disparity_v3, // shared memory + early termination
				compute_disparity_v4
		};

		kernel_function_t kernel_function = kernel_functions[kernel_version];
    // Check that block size and search range are valid
    if (patch_size <= 0 || patch_size % 2 == 0 || search_range <= 0) {
        cerr << "Error: invalid block size or search range" << endl;
        return 1;
    }


    // Read input images
    int left_width, left_height, left_channels;
    unsigned char* left_data = stbi_load(left_path.c_str(), &left_width, &left_height, &left_channels, 3);
    if (!left_data) {
        cerr << "Error: could not read the left input image 'view5.png'" << endl;
        return 1;
    }

    int right_width, right_height, right_channels;
    unsigned char* right_data = stbi_load(right_path.c_str(), &right_width, &right_height, &right_channels, 3);
    if (!right_data) {
        cerr << "Error: could not read the right image 'view1.png'" << endl;
        return 1;
    }

    // Convert input images to grayscale

    unsigned char* left_gray_data = new unsigned char[left_width * left_height];
    rgb2gray(left_data, left_width, left_height, left_gray_data);

    unsigned char* right_gray_data = new unsigned char[right_width * right_height];
    rgb2gray(right_data, right_width, right_height, right_gray_data);
		// Create output_images directory if it doesn't exist
		string output_dir = image_dir + "output_images/";
		DIR* dir = opendir(output_dir.c_str());
		if (dir) {
				closedir(dir);
		} else {
				mkdir(output_dir.c_str(), 0777);
		}  

		string output_path = output_dir + "/left_gray.png";
		// Write grayscale images to disk
		if (!stbi_write_png(output_path.c_str(), left_width, left_height, 1, left_gray_data, left_width)) {
				cerr << "Error: could not write output image 'left_gray.png'" << endl;
				return 1;
		}

  	output_path = output_dir + "/right_gray.png";	

		if (!stbi_write_png(output_path.c_str(), right_width, right_height, 1, right_gray_data, right_width)) {
				cerr << "Error: could not write output image 'right_gray.png'" << endl;
				return 1;
		}


		// Allocate memory for output disparity map
		int disp_width = left_width;
		int disp_height = left_height;
		unsigned char* disparity = new unsigned char[disp_width * disp_height];
 		auto start_time = std::chrono::system_clock::now();   
		// Declare and allocate device memory
		unsigned char *d_left_gray, *d_right_gray, *d_disparity;
		cudaMalloc((void **)&d_left_gray, left_width * left_height * sizeof(unsigned char));
		cudaMalloc((void **)&d_right_gray, right_width * right_height * sizeof(unsigned char));
		cudaMalloc((void **)&d_disparity, disp_width * disp_height * sizeof(unsigned char));

		// Copy input data to device
		cudaMemcpy(d_left_gray, left_gray_data, left_width * left_height * sizeof(unsigned char), cudaMemcpyHostToDevice);
		cudaMemcpy(d_right_gray, right_gray_data, right_width * right_height * sizeof(unsigned char), cudaMemcpyHostToDevice);

		// Set up kernel grid and block size
		//int gpu_block_dim = 2;
		dim3 block(gpu_block_dim,gpu_block_dim, 1);
		dim3 grid(ceil(disp_width + gpu_block_dim - 1) / gpu_block_dim, ceil(disp_height + gpu_block_dim - 1) / gpu_block_dim, 1);

		float elapsed_time = 0.0f;
		for (int i = 0; i < 10; i++) {
				cudaEvent_t start, stop;
				cudaEventCreate(&start);
				cudaEventCreate(&stop);
				cudaEventRecord(start);

				kernel_function<<<grid, block>>>(disp_width, disp_height, patch_size, search_range, d_left_gray, d_right_gray, d_disparity);
				cudaEventRecord(stop);
				cudaEventSynchronize(stop);

				float time_i = 0.0f;
				cudaMemcpy(disparity, d_disparity, disp_width * disp_height * sizeof(unsigned char), cudaMemcpyDeviceToHost);
				cudaEventElapsedTime(&time_i, start, stop);
				elapsed_time += time_i;
		}
		float avg_time = elapsed_time / 10.0f;
    // Write the input configurations and elapsed time to CSV file
    ofstream outfile;
    outfile.open("results.csv", ios_base::app); // open the file in append mode
    outfile << image_dir << "," << kernel_version << "," << gpu_block_dim << "," << patch_size << "," << search_range << "," << avg_time << endl;
    outfile.close();
    
    cout << "Average disparity estimation kernel execution time: " << avg_time << "ms" << endl;


	
		auto end_time = std::chrono::system_clock::now();
		auto program_time = std::chrono::duration_cast<std::chrono::milliseconds>(end_time - start_time).count();
		cout << "Total execution time: " << program_time << "ms" << endl;
		// Normalize output image for visualization
		normalize_image(disparity, disp_width, disp_height);





		output_path = output_dir + "/disparity_gpu_" + to_string(patch_size) + "_" + to_string(search_range)  + "_.png";

		// Write output disparity map to file
		stbi_write_png(output_path.c_str(), disp_width, disp_height, 1, disparity, disp_width);

		// Free device and host memory
		cudaFree(d_left_gray);
		cudaFree(d_right_gray);
		cudaFree(d_disparity);
		delete[] left_data;
		delete[] right_data;
		delete[] left_gray_data;
		delete[] right_gray_data;
		delete[] disparity;
	

		return 0;    
	
}
		  

