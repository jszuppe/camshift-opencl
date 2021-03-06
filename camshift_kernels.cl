#define R_LEVELS 16
#define G_LEVELS 16

#define MASK_RIGHT_MOST_BYTE_4	(uint4)(255)
#define MASK_RIGHT_MOST_BYTE	(uint)(255)

// 256 kube�k�w (16x16)
#define HIST_BINS 256

// Mapuje wybrany prostok�t z obrazu 2D RGBA @src
// na macierz 2D indeks�w histogramu RG @dst (16 x 16; indeks jest liczb� z zakresu 0 - 255).
// Ka�demu pixelowi przyporzadtkowywany jest odpowiedni indeks.
//
// Wybrany prostok�t jest definiowany przez @offset_x @offset_y i @rect_width.
//
// !! Z uwagi na to, �e przetwarzane s� 4 pixele jednoczesnie offset_x i rect_width musz� by� podana jako podzielone przez 4.
// 
// Potrzebne do stworzenia histogramu wybranego prostok�ta z obrazu.
//
__kernel void RGBA2RG_HIST_IDX_4(
	__global uint * src,
	__global uchar4 * dst,
    const uint rect_width, // Szerokosc prostok�tengo obszaru dla kt�rego obliczamy momenty
	const uint img_width, // Szeroko�� ca�ego obrazka
	const uint offset_x,  // Offset x
	const uint offset_y  // Offset y
	)
{    	
	const uint idx = 4 * (get_global_id(0) + offset_x) + (get_global_id(1)+offset_y) * img_width;
	const uint dst_idx = get_global_id(0) + get_global_id(1) * rect_width;
	
	uint4 rgba4 = (uint4)(src[idx],src[idx+1],src[idx+2],src[idx+3]);
	// OBLICZAM SUME R+G+B dla ka�dego pix
	// dodaje r
	uint4 r = (rgba4) & MASK_RIGHT_MOST_BYTE_4;
	uint4 sum_rgb = r;
	// dodaje g
	uint4 g = (rgba4 >> 8) & MASK_RIGHT_MOST_BYTE_4;
	sum_rgb += g;
	// dodaje b
	sum_rgb += ((rgba4 >> 16) & MASK_RIGHT_MOST_BYTE_4);
			
	// 16 * g
	uint4 rg_4 = g * (uint4)(16);
	// r + 16 * g
	rg_4 += r;
	// 15 * (r + 16 * g)
	rg_4 *= (uint4)(15);		
	// 15*(R+16*G) / (r+g+b)	
	rg_4 /= sum_rgb;
	// konwersja do uchar4 i zapis
	dst[dst_idx] = convert_uchar4_sat(rg_4);
}

// Mapowanie obrazu 2D RGBA @src na warto�ci z odpowiednich
// "kube�k�w"/indeks�w histogramu @histogram (16 x 16).
//
// Warto�ci zapisywane s� jako float w @dst ze wzgl�du na dalsze
// obliczenia (obliczenie moment�w).
__kernel void RGBA2HistScore(
	__global uint * src,
	const uint width,
	__global float * dst,
	__constant uint * histogram
	)
{
	uint idx = get_global_id(0) + get_global_id(1) * width;	

	// Ustalenie indeksu histogramuu
	uint rgba = src[idx];
	uint r = (rgba) & MASK_RIGHT_MOST_BYTE;
	uint g = (rgba >> 8) & MASK_RIGHT_MOST_BYTE;
	uint b = (rgba >> 16) & MASK_RIGHT_MOST_BYTE;

	uint hist_idx = ((r + 16 * g)*15)/(r+g+b);

	// Wpisanie warto�ci z pod odpowiedniego indeksu
	dst[idx] = (float)(histogram[hist_idx]);
}

#pragma OPENCL EXTENSION cl_khr_local_int32_base_atomics : enable

// Ile bank�w pami�ci u�ywamy
// Ze wzgl�du na to, �e SIMD wykonuje jednocze�nie �wier� wavefrontu (16 workitem�w)
// i b�dziemy u�ywa� operacji atomowy optymalnie wychodzi 16 chocia� jest 32.
#define NBANKS 16
#define BITS_PER_VALUE 8

// Oblicza histogram RG (16 x 16) @srcRG.
// 
// Algorytm dzia�a nast�puj�co: 
// *1 Ka�dy work-group ma NBANKS histogram�w lokalnych (�eby nie by�o problem�w z konfilktami do pami�ci lokalnej)
// * Jeden work-item przetwarza 16 razy @n4VectorsPerWorkItem warto�ci z @srcRG zwi�kszaj�c warto�c odpowiednich kube�k�w histogramu 
// (16 razy @n4VectorsPerWorkItem bo jedna warto�� jest 8-bitowa a wczytujemy wektory uint4, czyli 16 8-bitowych warto�ci, i ka�dy work-item wczytuje 
// @n4VectorsPerWorkItem wektor�w uint4).
// * Na ko�cu work-itemy sumuj� 16 histogram�w do jednego i zapisuj� w globalHistRG (szczeg�y ni�ej)
// * W globalHistRG jest ostatecznie tyle histogram�w ile jest work-group, sumowanie ostateczne jest po stronie hosta
// 
// Work-group powienien by� wielko�ci histogramu.
//
__kernel __attribute__((reqd_work_group_size(HIST_BINS,1,1)))
void histRG(
	__global uint4 * srcRG,
	__global uint * globalHistRG,
	uint n4VectorsPerWorkItem)
{
	__local uint subhists[NBANKS * HIST_BINS];

	uint gid = get_global_id(0);
	uint lid = get_local_id(0);
	uint Stride = get_global_size(0);
	
	const uint shift = BITS_PER_VALUE;
	const uint offset = lid % (uint)(NBANKS);
	uint4 tmp1, tmp2;	 
	
	// ZERUJE __local subhists
    uint localItemsPerWorkItem = NBANKS * HIST_BINS / get_local_size(0);
	uint localWorkItems = get_local_size(0);
	// Zerujemy po 4 jednoczesnie, bedzie szybciej i tak siegamy od innych bank�w
	__local uint4 *p = (__local uint4 *) subhists; 
    if( lid < localWorkItems )
    {
       for(uint i=0, idx=lid; i<localItemsPerWorkItem/4; i++, idx+=localWorkItems)
       {
          p[idx] = 0;
       }
    }
	barrier( CLK_LOCAL_MEM_FENCE );

	// Przegl�dam "obrazek" i wype�niam lokalny histogram
	for(uint i=0, idx=gid; i<n4VectorsPerWorkItem; i++, idx += Stride )
    {
       tmp1 = srcRG[idx];
       tmp2 = (tmp1 & MASK_RIGHT_MOST_BYTE_4) * (uint4) NBANKS + offset;

       (void) atom_inc( subhists + tmp2.x );
       (void) atom_inc( subhists + tmp2.y );
       (void) atom_inc( subhists + tmp2.z );
       (void) atom_inc( subhists + tmp2.w );

       tmp1 = tmp1 >> shift;
       tmp2 = (tmp1 & MASK_RIGHT_MOST_BYTE_4) * (uint4) NBANKS + offset;

       (void) atom_inc( subhists + tmp2.x );
       (void) atom_inc( subhists + tmp2.y );
       (void) atom_inc( subhists + tmp2.z );
       (void) atom_inc( subhists + tmp2.w );

       tmp1 = tmp1 >> shift;
       tmp2 = (tmp1 & MASK_RIGHT_MOST_BYTE_4) * (uint4) NBANKS + offset;
       
       (void) atom_inc( subhists + tmp2.x );
       (void) atom_inc( subhists + tmp2.y );
       (void) atom_inc( subhists + tmp2.z );
       (void) atom_inc( subhists + tmp2.w );

       tmp1 = tmp1 >> shift;
       tmp2 = (tmp1 & MASK_RIGHT_MOST_BYTE_4) * (uint4) NBANKS + offset;
       
       (void) atom_inc( subhists + tmp2.x );
       (void) atom_inc( subhists + tmp2.y );
       (void) atom_inc( subhists + tmp2.z );
       (void) atom_inc( subhists + tmp2.w );
    }
    barrier( CLK_LOCAL_MEM_FENCE );
	
	// Sumuje 16 lokalnych histogram�w w jeden histogram dla ca�ej work-group
	// Sumuje tak, ze ka�dy z 256 w�tk�w sumuje po jednym "kube�ku"/indeksie histogramu
	for(uint binIdx = lid; binIdx < HIST_BINS; binIdx += localWorkItems)
	{
		uint bin = 0;
		for( uint i = 0; i < NBANKS; i++)
		{
			bin += subhists[(lid*NBANKS) + ((i+lid) % NBANKS)];
		}
		globalHistRG[(get_group_id(0) * HIST_BINS) + binIdx] = bin;
	}	 
}


/**
* Oblicza momenty m00, m10, m01 dla prostok�tnego obszaru wewn�trz podanego obrazu.
*/
__kernel void moments(
    __global float * img, // Caly obraz
    __local float4 * scratch,
    const uint size, // Rozmiar obszaru dla ktorego obliczamy momenty
    const uint rect_width, // Szerokosc prostok�tengo obszaru dla kt�rego obliczamy momenty
	const uint img_width, // Szeroko�� ca�ego obrazka
	const uint offset_x,  // Offset x
	const uint offset_y,  // Offset y 
    __global float4* result // Wynik cz�ciowej redukcji, jeszcze trzeba doko�czy� redukcje po stronie hosta
	) 
{
    uint rect_idx = get_global_id(0);
    float4 accumulator = (float4)(0);

	// MOMENTY
	// START
	{	
		float frect_width = convert_float(rect_width);
			
		// Wsp�rzedne w prostok�tnym obszarze
		int rect_y = trunc(((float)rect_idx)/frect_width);
		int rect_x = rect_idx - rect_y * rect_width;

		// Wektor do wyliczania momentow
		// m00, m10, m01, -
		float4 m = (float4)(1.0, (float)rect_x, (float)rect_y, 0.0);

		// Cz�ciowa redukcja po��czona z obliczaniem
		// moment�w m00, m10, m01.
		while (rect_idx < size) 
		{
			float4 element = m * (float4)(img[rect_x + offset_x + ((rect_y + offset_y) * img_width)]);
			accumulator += element;
			rect_idx += get_global_size(0);
    
			// Wsp�rzedne w prostok�tnym obszarze
			rect_y = trunc(((float)rect_idx)/frect_width);
			rect_x = rect_idx - rect_y * rect_width;
			// Wektor do wyliczania moment�w
			m = (float4)(1.0, (float)rect_x, (float)rect_y, 0.0);
		}
	}
	// END
	// MOMENTY

    // REDUKCJA R�WNOLEG�A
	// START
    int lid = get_local_id(0);
    scratch[lid] = accumulator;
    barrier(CLK_LOCAL_MEM_FENCE);
    for(int offset = get_local_size(0) / 2; offset > 0; offset = offset / 2) 
    {
        if (lid < offset) 
        {
            float4 other = scratch[lid + offset];
            float4 mine = scratch[lid];
            scratch[lid] = mine + other;
        }
        barrier(CLK_LOCAL_MEM_FENCE);
    }
	// Zapis wyniku redukcji
    if (lid == 0) 
    {
        result[get_group_id(0)] = scratch[0];
    }
	// END
	// REDUKCJA
}