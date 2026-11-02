# Đánh giá hiệu năng MLO trên kiến trúc MLD

Mã nguồn và dữ liệu kèm đồ án “Đánh giá hiệu năng Multi-Link Operation trong mạng IEEE 802.11be bằng phương pháp mô phỏng”.

Tác giả: Hồ Đức Dũng.

Phiên bản công bố: 1.0.0 — tag v1.0.0.

## Môi trường mô phỏng

Các thực nghiệm sử dụng ns-3.46.1 trên Linux, với hai hiệu chỉnh cục bộ liên quan đến thiết lập Block Ack. Các hiệu chỉnh được phân phối trong ns3_prepare.sh.

Cấu hình dữ liệu cơ sở: EhtMcs9, BCC, một luồng không gian, GI 3200 ns, payload UDP 1200 byte và kênh 20 MHz trên mỗi liên kết. Các thay đổi cấu hình được xác định trong kế hoạch của từng demo.

## Bộ thực nghiệm

| Demo | Nội dung | Lượt chạy |
|---|---|---:|
| 1 | Quét tải với một STA và năm STA | 290 |
| 2 | Quét số STA tại hai mức tải mỗi STA | 460 |
| 3 | Khảo sát băng tần và độ rộng kênh | 25 |
| 4 | Khảo sát cách gán STA giữa các liên kết | 125 |
| 5 | Khảo sát fading, di chuyển và tải | 535 |
| Tổng | | 1435 |

Mỗi mục cấu hình sử dụng năm RNG run, từ 1 đến 5, với seed 1.

## Chuẩn bị và chạy mô phỏng

Chuẩn bị một cây ns-3.46.1 riêng. Sao chép các tệp C++ trong scratch/ vào scratch/ của ns-3; sao chép các Bash ở thư mục gốc vào thư mục chứa ns3 và VERSION.

Sao chép thêm validation/foundation-final-results.tar.gz vào thư mục validation/ bên trong cây ns-3.46.1. Tệp này được ns3_prepare.sh sử dụng để chuẩn bị các phần mã kiểm tra và nguồn thư viện đã hiệu chỉnh. Ba tệp .inc trong scratch/ns3-precheck-sources/ được tạo tự động khi thực hiện chế độ apply.

Thực hiện từ thư mục gốc ns-3:

```bash
bash ns3_prepare.sh inspect
bash ns3_prepare.sh apply
./ns3 configure
bash run_ns3_precheck.sh
```

Chạy lần lượt các demo:

```bash
bash run_demo_1.sh
bash run_demo_2.sh
bash run_demo_3.sh
bash run_demo_4.sh
bash run_demo_5.sh
```

Tiếp tục một lô bị gián đoạn bằng tùy chọn --resume, ví dụ:

```bash
bash run_demo_2.sh --resume
```

Resume yêu cầu dữ liệu từng case, dấu .done và thông tin của lô chạy. Các thư mục kết quả công bố trong kho chỉ chứa CSV tổng hợp và thông tin lô chạy để phục vụ phân tích.

## Phân tích dữ liệu

Từ thư mục chứa analyze_all_demos.py và năm thư mục kết quả:

```bash
python -m pip install -r requirements.txt
python analyze_all_demos.py --root .
```

Lệnh phân tích ghi lại đầu ra trong analysis_results/. Nên thực hiện trên một bản sao của gói công bố nếu cần giữ nguyên các đầu ra đã lưu.

## Quy ước chỉ tiêu

Throughput được đo ở tầng IP, bao gồm header IPv4 và UDP; tải cung cấp được xác định theo payload UDP trên mỗi STA. Khoảng đo của các demo là 9 giây.

Tỷ lệ không nhận được gói là chênh lệch phát–nhận tại thời điểm kết thúc, có thể gồm các gói còn tồn đọng. Delay và jitter được tính trên các gói đã nhận.

Jain được tính giữa các STA trong từng lượt chạy trước khi lấy trung bình qua năm RNG run. Thanh sai số trên biểu đồ biểu diễn độ lệch chuẩn mẫu, không phải khoảng tin cậy. 
## Bằng chứng kiểm tra

Thư mục validation/ chứa bằng chứng của bộ kiểm tra nền tảng 110 case, thực hiện qua hai phần 95 và 15 case, cùng dữ liệu đối chiếu một cảnh báo Block Ack.

Bộ mã chuẩn hóa ns3-precheck sử dụng kế hoạch 110 case từ bộ kiểm tra nền tảng đã thực hiện. Mã C++ gốc được khôi phục từ gói bằng chứng và kiểm tra bằng SHA-256 trước khi sử dụng. Kết quả thực thi của đầu mối chuẩn hóa, nếu chạy lại, được lưu riêng trong precheck_ns3_3461; các gói bằng chứng 95 và 15 case được giữ nguyên.

## Trích dẫn

Thông tin trích dẫn được cung cấp trong CITATION.cff.

Phiên bản gắn với báo cáo:
https://github.com/ducdungpk/wifi7-mld-thesis/tree/v1.0.0

## Ghi nhận mã nguồn

Các thông tin bản quyền và giấy phép của mã nguồn kế thừa được giữ trong các tệp tương ứng. Các hiệu chỉnh cục bộ được mô tả trong ns3_prepare.sh và phụ lục của báo cáo.

## Trích dẫn

Mã nguồn và dữ liệu sử dụng trong báo cáo được lưu trữ trên
Zenodo theo phiên bản 1.0.0.

Hồ Đức Dũng. (2026). Mã nguồn mô phỏng đánh giá hiệu năng MLO
trên kiến trúc MLD (phiên bản 1.0.0). Zenodo.
https://doi.org/10.5281/zenodo.23875063

Thông tin trích dẫn có trong CITATION.cff.